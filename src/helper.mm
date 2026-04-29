// helper.mm — sidecar executable for libwkhtmltox.dylib (macOS arm64).
// Renders HTML to PDF using WKWebView + NSPrintOperation on its own NSApp
// main run loop. Communicates with the parent dylib over stdin/stdout using
// length-prefixed binary frames.
//
// Protocol (big-endian u32 lengths on every frame):
//   stdin  : [u32 cfg_len][cfg_len bytes JSON][u32 html_len][html_len bytes UTF-8]
//   stdout : [u32 status][u32 body_len][body_len bytes]
//            status = 1 -> body is the PDF
//            status = 0 -> body is a UTF-8 error message

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#import <WebKit/WebKit.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

// ---------- debug tracing -------------------------------------------------

static void trace(const char* fmt, ...) {
    static int enabled = -1;
    if (enabled == -1) {
        const char* e = getenv("WKHTMLTOX_HELPER_TRACE");
        enabled = (e && *e) ? 1 : 0;
    }
    if (!enabled) return;
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[helper] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    fflush(stderr);
    va_end(ap);
}

// ---------- length-prefixed binary IO ------------------------------------

static bool read_full(int fd, void* buf, size_t n) {
    uint8_t* p = (uint8_t*)buf; size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) { if (errno == EINTR) continue; return false; }
        if (r == 0) return false;
        got += (size_t)r;
    }
    return true;
}
static bool write_full(int fd, const void* buf, size_t n) {
    const uint8_t* p = (const uint8_t*)buf; size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, p + sent, n - sent);
        if (w < 0) { if (errno == EINTR) continue; return false; }
        sent += (size_t)w;
    }
    return true;
}
static bool read_u32_be(int fd, uint32_t* out) {
    uint8_t b[4];
    if (!read_full(fd, b, 4)) return false;
    *out = ((uint32_t)b[0]<<24) | ((uint32_t)b[1]<<16) |
           ((uint32_t)b[2]<<8)  |  (uint32_t)b[3];
    return true;
}
static bool write_u32_be(int fd, uint32_t v) {
    uint8_t b[4] = { (uint8_t)((v>>24)&0xFF), (uint8_t)((v>>16)&0xFF),
                     (uint8_t)((v>>8) &0xFF), (uint8_t)(v & 0xFF) };
    return write_full(fd, b, 4);
}
static void emit_failure(NSString* message) {
    NSData* msg = [message dataUsingEncoding:NSUTF8StringEncoding];
    write_u32_be(STDOUT_FILENO, 0u);
    write_u32_be(STDOUT_FILENO, (uint32_t)msg.length);
    write_full(STDOUT_FILENO, msg.bytes, msg.length);
}
static void emit_success(NSData* pdf) {
    write_u32_be(STDOUT_FILENO, 1u);
    write_u32_be(STDOUT_FILENO, (uint32_t)pdf.length);
    write_full(STDOUT_FILENO, pdf.bytes, pdf.length);
}

// ---------- WKWebView load delegate --------------------------------------

@interface HelperDelegate : NSObject <WKNavigationDelegate>
@property (nonatomic, copy) void (^onComplete)(BOOL ok, NSString* err);
@end

@implementation HelperDelegate
- (void)webView:(WKWebView*)w didFinishNavigation:(WKNavigation*)n {
    trace("didFinishNavigation");
    if (self.onComplete) { self.onComplete(YES, nil); self.onComplete = nil; }
}
- (void)webView:(WKWebView*)w didFailNavigation:(WKNavigation*)n withError:(NSError*)e {
    trace("didFailNavigation: %s", e.localizedDescription.UTF8String ?: "?");
    if (self.onComplete) { self.onComplete(NO, e.localizedDescription); self.onComplete = nil; }
}
- (void)webView:(WKWebView*)w didFailProvisionalNavigation:(WKNavigation*)n withError:(NSError*)e {
    trace("didFailProvisionalNavigation: %s", e.localizedDescription.UTF8String ?: "?");
    if (self.onComplete) { self.onComplete(NO, e.localizedDescription); self.onComplete = nil; }
}
@end

@interface RenderJob : NSObject
@property (nonatomic, strong) WKWebView*       web;
@property (nonatomic, strong) HelperDelegate*  navDelegate;
@property (nonatomic, strong) NSWindow*        window;
@property (nonatomic, copy)   void (^onDone)(NSData* pdf, NSString* err);
@end
@implementation RenderJob
@end

// ---------- main render path (must run on the NSApp main thread) ---------

static void start_render(NSString* html,
                         NSDictionary* cfg,
                         void (^done)(NSData* pdf, NSString* err)) {
    double paperW   = [cfg[@"paper_w_pt"]       doubleValue];
    double paperH   = [cfg[@"paper_h_pt"]       doubleValue];
    double mTop     = [cfg[@"margin_top_pt"]    doubleValue];
    double mRight   = [cfg[@"margin_right_pt"]  doubleValue];
    double mBottom  = [cfg[@"margin_bottom_pt"] doubleValue];
    double mLeft    = [cfg[@"margin_left_pt"]   doubleValue];
    double timeout  = cfg[@"load_timeout_sec"] ? [cfg[@"load_timeout_sec"] doubleValue] : 30.0;
    BOOL   js       = cfg[@"javascript"]       ? [cfg[@"javascript"]       boolValue]   : YES;

    if (paperW < 36)  paperW  = 595.0;
    if (paperH < 36)  paperH  = 842.0;
    if (mTop    < 0) mTop    = 0;
    if (mRight  < 0) mRight  = 0;
    if (mBottom < 0) mBottom = 0;
    if (mLeft   < 0) mLeft   = 0;

    WKWebViewConfiguration* wkcfg = [[WKWebViewConfiguration alloc] init];
    if (@available(macOS 11.0, *)) {
        wkcfg.defaultWebpagePreferences.allowsContentJavaScript = js;
    }

    // Use full-paper dimensions for the web view; createPDFWithConfiguration
    // will respect the rect and produce a single page sized to the rect.
    // Web fonts/CSS layout uses CSS pixels (96dpi) -> convert pt to px.
    CGFloat fullWpx  = paperW * 96.0 / 72.0;
    CGFloat fullHpx  = paperH * 96.0 / 72.0;
    NSRect frame = NSMakeRect(0, 0, fullWpx, fullHpx);

    RenderJob* job = [[RenderJob alloc] init];
    job.web         = [[WKWebView alloc] initWithFrame:frame configuration:wkcfg];
    job.navDelegate = [[HelperDelegate alloc] init];
    job.web.navigationDelegate = job.navDelegate;
    job.onDone = done;

    // Off-screen borderless window. Required so WebKit fully lays out the
    // page (compositor needs an attached host view).
    NSRect offscreen = NSMakeRect(-20000, -20000, fullWpx, fullHpx);
    NSWindow* win = [[NSWindow alloc] initWithContentRect:offscreen
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.releasedWhenClosed = NO;
    win.contentView = job.web;
    [win orderBack:nil];
    job.window = win;

    // Watchdog: if the load never completes, fail with timeout.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (job.navDelegate.onComplete) {
            void (^cb)(BOOL, NSString*) = job.navDelegate.onComplete;
            job.navDelegate.onComplete = nil;
            cb(NO, @"Timeout loading HTML in WKWebView.");
        }
    });

    job.navDelegate.onComplete = ^(BOOL ok, NSString* err) {
        if (!ok) {
            if (job.onDone) job.onDone(nil,
                [NSString stringWithFormat:@"WKWebView load failed: %@",
                                           err ?: @"unknown"]);
            return;
        }

        // Settle web fonts/late JS, then size for full content and paginate.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // Measure document scroll height in CSS pixels.
            [job.web evaluateJavaScript:
                @"Math.max(document.documentElement.scrollHeight,"
                @"         document.body ? document.body.scrollHeight : 0)"
                  completionHandler:^(id result, NSError* jsErr) {
                if (jsErr) {
                    if (job.onDone) job.onDone(nil,
                        [NSString stringWithFormat:@"scrollHeight JS failed: %@",
                                                   jsErr.localizedDescription]);
                    return;
                }
                CGFloat scrollPx = [result respondsToSelector:@selector(doubleValue)]
                                    ? [result doubleValue] : fullHpx;
                if (scrollPx < fullHpx) scrollPx = fullHpx;

                // Resize web view to full content height in CSS pixels.
                NSRect newFrame = NSMakeRect(0, 0, fullWpx, scrollPx);
                [job.web setFrame:newFrame];
                [job.window setContentSize:NSMakeSize(fullWpx, scrollPx)];
                trace("scrollPx=%.1f (page=%.1f)", (double)scrollPx, (double)fullHpx);

                // Force layout settle before capture.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (@available(macOS 11.0, *)) {
                        // Margins are in CSS pixels for clipping the
                        // captured rect; we keep them out for now and let
                        // the HTML control its own padding. (DinkToPdf-
                        // style margins are added by inset-cropping the
                        // capture region below.)
                        CGFloat mt = mTop    * 96.0 / 72.0;
                        CGFloat mr = mRight  * 96.0 / 72.0;
                        CGFloat mb = mBottom * 96.0 / 72.0;
                        CGFloat ml = mLeft   * 96.0 / 72.0;

                        // Capture full content (without margins applied)
                        // and paginate by slicing in CSS-pixel page heights.
                        CGFloat pageContentWpx = fullWpx; // we don't shrink the WebView width; margins applied to PDF placement.
                        CGFloat pageContentHpx = fullHpx; // each page slice height (paperH in px).

                        // Build a CG PDF context to assemble pages.
                        NSMutableData* outData = [NSMutableData data];
                        CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(
                            (__bridge CFMutableDataRef)outData);
                        CGRect mediaBox = CGRectMake(0, 0, paperW, paperH);
                        CGContextRef pdfCtx = CGPDFContextCreate(consumer, &mediaBox, NULL);
                        CGDataConsumerRelease(consumer);

                        // Recursive pagination: capture one slice at a time
                        // and draw into a new PDF page.
                        __block NSInteger pageIndex = 0;
                        __block void (^renderNext)(void) = nil;
                        CGFloat totalPx = scrollPx;
                        NSInteger totalPages = (NSInteger)ceil(totalPx / pageContentHpx);
                        if (totalPages < 1) totalPages = 1;

                        renderNext = ^{
                            if (pageIndex >= totalPages) {
                                CGPDFContextClose(pdfCtx);
                                CGContextRelease(pdfCtx);
                                if (outData.length == 0) {
                                    if (job.onDone) job.onDone(nil,
                                        @"Empty PDF produced (paginate).");
                                    return;
                                }
                                if (job.onDone) job.onDone(outData, nil);
                                return;
                            }

                            CGFloat yTop = pageIndex * pageContentHpx;
                            CGFloat sliceH = MIN(pageContentHpx, totalPx - yTop);
                            // Skip degenerate trailing slices (<2 css px tall).
                            // Common when scrollHeight overshoots by a fraction.
                            if (sliceH < 2.0) {
                                trace("skip tiny tail page %ld (h=%.2f)",
                                      (long)pageIndex+1, (double)sliceH);
                                pageIndex = totalPages;
                                dispatch_async(dispatch_get_main_queue(), renderNext);
                                return;
                            }
                            WKPDFConfiguration* cfg2 = [[WKPDFConfiguration alloc] init];
                            cfg2.rect = NSMakeRect(0, yTop, pageContentWpx, sliceH);
                            trace("page %ld/%ld y=%.1f h=%.1f",
                                  (long)pageIndex+1, (long)totalPages,
                                  (double)yTop, (double)sliceH);
                            [job.web createPDFWithConfiguration:cfg2
                                              completionHandler:^(NSData* slice, NSError* sErr) {
                                trace("  slice %ld returned bytes=%lu err=%s",
                                      (long)pageIndex+1,
                                      (unsigned long)slice.length,
                                      sErr.localizedDescription.UTF8String ?: "");
                                if (sErr || !slice || slice.length == 0) {
                                    CGContextRelease(pdfCtx);
                                    if (job.onDone) job.onDone(nil,
                                        sErr ? [NSString stringWithFormat:
                                                @"createPDF page %ld: %@",
                                                (long)pageIndex+1, sErr.localizedDescription]
                                             : @"createPDF returned empty slice");
                                    return;
                                }
                                // Read slice page 1 and draw onto our PDF page.
                                CGDataProviderRef prov = CGDataProviderCreateWithCFData(
                                    (__bridge CFDataRef)slice);
                                CGPDFDocumentRef sliceDoc = CGPDFDocumentCreateWithProvider(prov);
                                CGDataProviderRelease(prov);
                                if (!sliceDoc || CGPDFDocumentGetNumberOfPages(sliceDoc) < 1) {
                                    if (sliceDoc) CGPDFDocumentRelease(sliceDoc);
                                    CGContextRelease(pdfCtx);
                                    if (job.onDone) job.onDone(nil,
                                        @"slice PDF unreadable");
                                    return;
                                }
                                CGPDFPageRef page = CGPDFDocumentGetPage(sliceDoc, 1);
                                CGRect srcBox = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);

                                CGContextBeginPage(pdfCtx, &mediaBox);
                                // Place slice inside margins. Slice intrinsic
                                // size = (pageContentWpx, sliceH) in PDF pts;
                                // scale to fit (paperW - ml - mr) wide.
                                CGFloat targetW = paperW - ml - mr;
                                CGFloat scale   = targetW / srcBox.size.width;
                                CGFloat targetH = srcBox.size.height * scale;
                                // Position from the top: PDF coords have
                                // origin at bottom-left.
                                CGFloat tx = ml;
                                CGFloat ty = paperH - mt - targetH;
                                CGContextSaveGState(pdfCtx);
                                CGContextTranslateCTM(pdfCtx, tx, ty);
                                CGContextScaleCTM(pdfCtx, scale, scale);
                                CGContextDrawPDFPage(pdfCtx, page);
                                CGContextRestoreGState(pdfCtx);
                                CGContextEndPage(pdfCtx);
                                CGPDFDocumentRelease(sliceDoc);

                                pageIndex++;
                                dispatch_async(dispatch_get_main_queue(), renderNext);
                            }];
                        };
                        renderNext();
                    } else {
                        if (job.onDone) job.onDone(nil, @"macOS 11+ required.");
                    }
                });
            }];
        });
    };

    trace("loadHTMLString len=%lu", (unsigned long)html.length);
    [job.web loadHTMLString:html baseURL:nil];
}

// ---------- main ---------------------------------------------------------

int main(int argc, char** argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        trace("helper start pid=%d", (int)getpid());

        // 1) Read JSON config
        uint32_t jlen = 0;
        if (!read_u32_be(STDIN_FILENO, &jlen) || jlen > (16u * 1024u * 1024u)) {
            emit_failure(@"helper: failed to read config length");
            return 1;
        }
        NSMutableData* jbuf = [NSMutableData dataWithLength:jlen];
        if (jlen > 0 && !read_full(STDIN_FILENO, jbuf.mutableBytes, jlen)) {
            emit_failure(@"helper: failed to read config bytes");
            return 1;
        }
        NSError* jerr = nil;
        id parsed = jlen > 0
            ? [NSJSONSerialization JSONObjectWithData:jbuf options:0 error:&jerr]
            : @{};
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            emit_failure([NSString stringWithFormat:@"helper: config not a JSON object (%@)",
                                                    jerr.localizedDescription ?: @"?"]);
            return 1;
        }
        NSDictionary* cfg = parsed;

        // 2) Read HTML (UTF-8)
        uint32_t hlen = 0;
        if (!read_u32_be(STDIN_FILENO, &hlen) || hlen > (256u * 1024u * 1024u)) {
            emit_failure(@"helper: failed to read html length");
            return 1;
        }
        NSMutableData* hbuf = [NSMutableData dataWithLength:hlen];
        if (hlen > 0 && !read_full(STDIN_FILENO, hbuf.mutableBytes, hlen)) {
            emit_failure(@"helper: failed to read html bytes");
            return 1;
        }
        NSString* html = [[NSString alloc] initWithData:hbuf
                                               encoding:NSUTF8StringEncoding] ?: @"";
        trace("read html_len=%u", (unsigned)hlen);

        // 3) Bring up NSApp and run a private main loop.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        __block NSData*    out_pdf = nil;
        __block NSString*  out_err = nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            start_render(html, cfg, ^(NSData* pdf, NSString* err) {
                out_pdf = pdf;
                out_err = err;
                trace("render done; stopping NSApp (pdf=%lu err=%s)",
                      (unsigned long)pdf.length,
                      err.UTF8String ?: "");
                [NSApp stop:nil];
                NSEvent* dummy =
                    [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
                [NSApp postEvent:dummy atStart:YES];
            });
        });

        [NSApp run];

        // 4) Emit result.
        if (out_pdf && out_pdf.length > 0) {
            emit_success(out_pdf);
            return 0;
        }
        emit_failure(out_err ?: @"helper: render produced no PDF");
        return 1;
    }
}
