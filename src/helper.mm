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

// ---------- header / footer rendering ------------------------------------

// Replace wkhtmltopdf template variables in a header/footer string.
// Supports: [page], [topage], [toPage], [title], [date], [time],
//           [sitepage], [sitepages].
static NSString* subst_vars(NSString* tmpl,
                             NSInteger page, NSInteger total,
                             NSString* title,
                             NSString* dateStr, NSString* timeStr) {
    if (!tmpl || tmpl.length == 0) return @"";
    NSString* s = tmpl;
    NSString* pageS  = [@(page)  description];
    NSString* totalS = [@(total) description];
    s = [s stringByReplacingOccurrencesOfString:@"[page]"      withString:pageS];
    s = [s stringByReplacingOccurrencesOfString:@"[topage]"    withString:totalS];
    s = [s stringByReplacingOccurrencesOfString:@"[toPage]"    withString:totalS];
    s = [s stringByReplacingOccurrencesOfString:@"[sitepage]"  withString:pageS];
    s = [s stringByReplacingOccurrencesOfString:@"[sitepages]" withString:totalS];
    s = [s stringByReplacingOccurrencesOfString:@"[title]"     withString:title   ?: @""];
    s = [s stringByReplacingOccurrencesOfString:@"[date]"      withString:dateStr ?: @""];
    s = [s stringByReplacingOccurrencesOfString:@"[time]"      withString:timeStr ?: @""];
    return s;
}

// Draw left/center/right text and optional separator line into a PDF page.
//
// Coordinate system: PDF standard (origin bottom-left, y increases upward).
//
// For headers (isHeader=YES):
//   band spans [bandY, bandY+bandH] where bandY = paperH - marginTop
//   text baseline near the TOP of the band
//   separator line near the BOTTOM of the band (above content)
//
// For footers (isHeader=NO):
//   band spans [bandY, bandY+bandH] where bandY = 0, bandH = marginBottom
//   text baseline near the BOTTOM of the band
//   separator line near the TOP of the band (below content)
static void draw_band(CGContextRef pdfCtx,
                      NSString* leftTmpl, NSString* centerTmpl, NSString* rightTmpl,
                      NSString* fontName, CGFloat fontSize,
                      BOOL showLine, CGFloat spacingPt,
                      CGFloat bandX, CGFloat bandW,
                      CGFloat bandY, CGFloat bandH,
                      BOOL isHeader,
                      NSInteger pageNum, NSInteger totalPages,
                      NSString* title, NSString* dateStr, NSString* timeStr) {
    @autoreleasepool {
        NSString* L = subst_vars(leftTmpl,   pageNum, totalPages, title, dateStr, timeStr);
        NSString* C = subst_vars(centerTmpl, pageNum, totalPages, title, dateStr, timeStr);
        NSString* R = subst_vars(rightTmpl,  pageNum, totalPages, title, dateStr, timeStr);

        BOOL hasText = (L.length > 0 || C.length > 0 || R.length > 0);
        if (!hasText && !showLine) return;

        CGContextSaveGState(pdfCtx);

        if (hasText) {
            NSFont* font = [NSFont fontWithName:fontName size:fontSize];
            if (!font) font = [NSFont systemFontOfSize:fontSize];

            NSDictionary* attrs = @{
                NSFontAttributeName:            font,
                NSForegroundColorAttributeName: [NSColor blackColor],
            };

            // Text baseline:
            //   Header → near top of band (4pt padding, text hangs down from baseline)
            //   Footer → near bottom of band (4pt padding from bottom)
            CGFloat textY;
            if (isHeader) {
                textY = bandY + bandH - 4.0 - fontSize;
            } else {
                textY = bandY + 4.0;
            }
            textY = MAX(bandY, MIN(textY, bandY + bandH - fontSize));

            NSGraphicsContext* saved = [NSGraphicsContext currentContext];
            NSGraphicsContext* ctx =
                [NSGraphicsContext graphicsContextWithCGContext:pdfCtx flipped:NO];
            [NSGraphicsContext setCurrentContext:ctx];

            if (L.length > 0)
                [L drawAtPoint:NSMakePoint(bandX, textY) withAttributes:attrs];

            if (C.length > 0) {
                CGFloat cw = [C sizeWithAttributes:attrs].width;
                [C drawAtPoint:NSMakePoint(bandX + bandW / 2.0 - cw / 2.0, textY)
                withAttributes:attrs];
            }

            if (R.length > 0) {
                CGFloat rw = [R sizeWithAttributes:attrs].width;
                [R drawAtPoint:NSMakePoint(bandX + bandW - rw, textY)
                withAttributes:attrs];
            }

            [NSGraphicsContext setCurrentContext:saved];
        }

        if (showLine) {
            // Line sits at the content-facing edge of the band, inset by spacingPt.
            // Header: line at bandY + max(spacingPt, 2)  (above content start)
            // Footer: line at bandY + bandH - max(spacingPt, 2)  (below content end)
            CGFloat gap = MAX(spacingPt, 2.0);
            CGFloat lineY = isHeader ? (bandY + gap) : (bandY + bandH - gap);

            CGContextSetStrokeColorWithColor(pdfCtx, [NSColor blackColor].CGColor);
            CGContextSetLineWidth(pdfCtx, 0.5);
            CGContextMoveToPoint(pdfCtx, bandX, lineY);
            CGContextAddLineToPoint(pdfCtx, bandX + bandW, lineY);
            CGContextStrokePath(pdfCtx);
        }

        CGContextRestoreGState(pdfCtx);
    }
}

// ---------- PDF outline (bookmarks) from headings -------------------------

// Build a nested PDF outline.
// headings: NSArray of NSArray [level(NSNumber), text(NSString), offsetTopPx(NSNumber)]
// pageContentHpx: height of one page in CSS pixels (= paperH * 96/72)
static void build_pdf_outline(PDFDocument* doc,
                               NSArray* headings,
                               CGFloat pageContentHpx,
                               NSInteger maxDepth) {
    if (!doc || headings.count == 0) return;

    PDFOutline* root = [[PDFOutline alloc] init];
    // stack items: [levelNSNumber, PDFOutline*]
    NSMutableArray* stack = [NSMutableArray array];

    for (NSArray* entry in headings) {
        if (entry.count < 3) continue;
        NSInteger level = [entry[0] integerValue];
        NSString* text  = entry[1];
        CGFloat   topPx = [entry[2] doubleValue];

        if (level < 1 || level > maxDepth) continue;
        if (!text || text.length == 0) continue;

        NSInteger pageIdx = (NSInteger)(topPx / pageContentHpx);
        pageIdx = MAX(0, MIN(pageIdx, (NSInteger)doc.pageCount - 1));

        PDFPage* pdfPage  = [doc pageAtIndex:(NSUInteger)pageIdx];
        CGRect   bounds   = [pdfPage boundsForBox:kPDFDisplayBoxMediaBox];
        PDFDestination* dest = [[PDFDestination alloc]
                                    initWithPage:pdfPage
                                         atPoint:NSMakePoint(0, bounds.size.height)];

        PDFOutline* item  = [[PDFOutline alloc] init];
        item.label        = text;
        item.destination  = dest;

        // Pop stack until we find a shallower ancestor.
        while (stack.count > 0 && [stack.lastObject[0] integerValue] >= level)
            [stack removeLastObject];

        PDFOutline* parent = stack.count > 0 ? stack.lastObject[1] : root;
        [parent insertChild:item atIndex:(NSUInteger)parent.numberOfChildren];
        [stack addObject:@[@(level), item]];
    }

    if (root.numberOfChildren > 0)
        doc.outlineRoot = root;
}

// JS snippet that returns a nested array of [level, text, offsetTopPx] for
// every h1-h6 element in the document, using absolute scroll-adjusted positions.
static NSString* kHeadingsJS =
    @"(function(){"
    @"var hs=document.querySelectorAll('h1,h2,h3,h4,h5,h6');"
    @"var r=[];"
    @"for(var i=0;i<hs.length;i++){"
    @"  var h=hs[i];"
    @"  var rect=h.getBoundingClientRect();"
    @"  var st=window.pageYOffset||document.documentElement.scrollTop;"
    @"  r.push([parseInt(h.tagName.charAt(1)),"
    @"          (h.textContent||'').trim().replace(/\\s+/g,' ').substring(0,200),"
    @"          Math.round(rect.top+st)]);"
    @"}"
    @"return r;"
    @"})()";

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

    // ---- Header / footer config ------------------------------------------

    NSString* hdrLeft      = cfg[@"header_left"]        ?: @"";
    NSString* hdrCenter    = cfg[@"header_center"]      ?: @"";
    NSString* hdrRight     = cfg[@"header_right"]       ?: @"";
    CGFloat   hdrFontSize  = cfg[@"header_font_size"]   ? [cfg[@"header_font_size"]  doubleValue] : 9.0;
    NSString* hdrFontName  = cfg[@"header_font_name"]   ?: @"Helvetica";
    BOOL      hdrLine      = cfg[@"header_line"]        ? [cfg[@"header_line"]       boolValue]   : NO;
    CGFloat   hdrSpacing   = cfg[@"header_spacing_pt"]  ? [cfg[@"header_spacing_pt"] doubleValue] : 0.0;

    NSString* ftrLeft      = cfg[@"footer_left"]        ?: @"";
    NSString* ftrCenter    = cfg[@"footer_center"]      ?: @"";
    NSString* ftrRight     = cfg[@"footer_right"]       ?: @"";
    CGFloat   ftrFontSize  = cfg[@"footer_font_size"]   ? [cfg[@"footer_font_size"]  doubleValue] : 9.0;
    NSString* ftrFontName  = cfg[@"footer_font_name"]   ?: @"Helvetica";
    BOOL      ftrLine      = cfg[@"footer_line"]        ? [cfg[@"footer_line"]       boolValue]   : NO;
    CGFloat   ftrSpacing   = cfg[@"footer_spacing_pt"]  ? [cfg[@"footer_spacing_pt"] doubleValue] : 0.0;

    NSString* cfgTitle     = cfg[@"document_title"]     ?: @"";

    BOOL hasHeader = (hdrLeft.length > 0 || hdrCenter.length > 0 ||
                      hdrRight.length > 0 || hdrLine);
    BOOL hasFooter = (ftrLeft.length > 0 || ftrCenter.length > 0 ||
                      ftrRight.length > 0 || ftrLine);

    // ---- Outline (PDF bookmarks) config ----------------------------------

    BOOL      includeOutline = cfg[@"outline"]       ? [cfg[@"outline"] boolValue]      : NO;
    NSInteger outlineDepth   = cfg[@"outline_depth"] ? [cfg[@"outline_depth"] intValue] : 4;

    // Compute date/time strings once for the whole document.
    NSDateFormatter* dateFmt = [[NSDateFormatter alloc] init];
    [dateFmt setDateStyle:NSDateFormatterShortStyle];
    [dateFmt setTimeStyle:NSDateFormatterNoStyle];
    NSString* dateStr = [dateFmt stringFromDate:[NSDate date]];
    [dateFmt setDateStyle:NSDateFormatterNoStyle];
    [dateFmt setTimeStyle:NSDateFormatterShortStyle];
    NSString* timeStr = [dateFmt stringFromDate:[NSDate date]];

    // ---- WebView setup --------------------------------------------------

    WKWebViewConfiguration* wkcfg = [[WKWebViewConfiguration alloc] init];
    if (@available(macOS 11.0, *)) {
        wkcfg.defaultWebpagePreferences.allowsContentJavaScript = js;
    }

    CGFloat fullWpx  = paperW * 96.0 / 72.0;
    CGFloat fullHpx  = paperH * 96.0 / 72.0;
    NSRect frame = NSMakeRect(0, 0, fullWpx, fullHpx);

    RenderJob* job = [[RenderJob alloc] init];
    job.web         = [[WKWebView alloc] initWithFrame:frame configuration:wkcfg];
    job.navDelegate = [[HelperDelegate alloc] init];
    job.web.navigationDelegate = job.navDelegate;
    job.onDone = done;

    NSRect offscreen = NSMakeRect(-20000, -20000, fullWpx, fullHpx);
    NSWindow* win = [[NSWindow alloc] initWithContentRect:offscreen
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.releasedWhenClosed = NO;
    win.contentView = job.web;
    [win orderBack:nil];
    job.window = win;

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

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
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

                NSRect newFrame = NSMakeRect(0, 0, fullWpx, scrollPx);
                [job.web setFrame:newFrame];
                [job.window setContentSize:NSMakeSize(fullWpx, scrollPx)];
                trace("scrollPx=%.1f (page=%.1f)", (double)scrollPx, (double)fullHpx);

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (@available(macOS 11.0, *)) {

                        // --- Pagination block (called after all pre-render JS evals) ---
                        void (^startPagination)(NSString*, NSArray*) =
                            ^(NSString* docTitle, NSArray* headings) {

                            CGFloat mt = mTop    * 96.0 / 72.0;
                            CGFloat mr = mRight  * 96.0 / 72.0;
                            CGFloat mb = mBottom * 96.0 / 72.0;
                            CGFloat ml = mLeft   * 96.0 / 72.0;

                            CGFloat pageContentWpx = fullWpx;
                            CGFloat pageContentHpx = fullHpx;

                            NSMutableData* outData = [NSMutableData data];
                            CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData(
                                (__bridge CFMutableDataRef)outData);
                            CGRect mediaBox = CGRectMake(0, 0, paperW, paperH);
                            CGContextRef pdfCtx = CGPDFContextCreate(consumer, &mediaBox, NULL);
                            CGDataConsumerRelease(consumer);

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
                                    // Post-process: add PDF outline if requested.
                                    NSData* finalPdf = outData;
                                    if (includeOutline && headings.count > 0) {
                                        PDFDocument* pdfDoc =
                                            [[PDFDocument alloc] initWithData:outData];
                                        if (pdfDoc) {
                                            build_pdf_outline(pdfDoc, headings,
                                                              pageContentHpx, outlineDepth);
                                            NSData* outlined = [pdfDoc dataRepresentation];
                                            if (outlined && outlined.length > 0)
                                                finalPdf = outlined;
                                        }
                                    }
                                    if (job.onDone) job.onDone(finalPdf, nil);
                                    return;
                                }

                                CGFloat yTop  = pageIndex * pageContentHpx;
                                CGFloat sliceH = MIN(pageContentHpx, totalPx - yTop);
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
                                    CGDataProviderRef prov = CGDataProviderCreateWithCFData(
                                        (__bridge CFDataRef)slice);
                                    CGPDFDocumentRef sliceDoc = CGPDFDocumentCreateWithProvider(prov);
                                    CGDataProviderRelease(prov);
                                    if (!sliceDoc || CGPDFDocumentGetNumberOfPages(sliceDoc) < 1) {
                                        if (sliceDoc) CGPDFDocumentRelease(sliceDoc);
                                        CGContextRelease(pdfCtx);
                                        if (job.onDone) job.onDone(nil, @"slice PDF unreadable");
                                        return;
                                    }
                                    CGPDFPageRef page = CGPDFDocumentGetPage(sliceDoc, 1);
                                    CGRect srcBox = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);

                                    CGContextBeginPage(pdfCtx, &mediaBox);

                                    // Draw content inside margins.
                                    CGFloat targetW = paperW - ml - mr;
                                    CGFloat scale   = targetW / srcBox.size.width;
                                    CGFloat targetH = srcBox.size.height * scale;
                                    CGFloat tx = ml;
                                    CGFloat ty = paperH - mTop - targetH;
                                    CGContextSaveGState(pdfCtx);
                                    CGContextTranslateCTM(pdfCtx, tx, ty);
                                    CGContextScaleCTM(pdfCtx, scale, scale);
                                    CGContextDrawPDFPage(pdfCtx, page);
                                    CGContextRestoreGState(pdfCtx);
                                    CGPDFDocumentRelease(sliceDoc);

                                    // Draw header and footer bands.
                                    NSInteger curPage = pageIndex + 1;
                                    CGFloat bandX = ml;
                                    CGFloat bandW = paperW - ml - mr;

                                    if (hasHeader) {
                                        draw_band(pdfCtx,
                                                  hdrLeft, hdrCenter, hdrRight,
                                                  hdrFontName, hdrFontSize,
                                                  hdrLine, hdrSpacing,
                                                  bandX, bandW,
                                                  paperH - mTop, mTop,
                                                  YES,
                                                  curPage, totalPages,
                                                  docTitle, dateStr, timeStr);
                                    }

                                    if (hasFooter) {
                                        draw_band(pdfCtx,
                                                  ftrLeft, ftrCenter, ftrRight,
                                                  ftrFontName, ftrFontSize,
                                                  ftrLine, ftrSpacing,
                                                  bandX, bandW,
                                                  0.0, mBottom,
                                                  NO,
                                                  curPage, totalPages,
                                                  docTitle, dateStr, timeStr);
                                    }

                                    CGContextEndPage(pdfCtx);

                                    pageIndex++;
                                    dispatch_async(dispatch_get_main_queue(), renderNext);
                                }];
                            };
                            renderNext();
                        }; // startPagination

                        // --- Sequential pre-render evals: headings → title → paginate ---

                        // 2. After headings: fetch title (if needed), then paginate.
                        void (^afterHeadings)(NSArray*) = ^(NSArray* headings) {
                            if (hasHeader || hasFooter) {
                                [job.web evaluateJavaScript:@"document.title"
                                          completionHandler:^(id r, NSError* e) {
                                    NSString* t = [r isKindOfClass:[NSString class]] ? r : cfgTitle;
                                    startPagination(t.length > 0 ? t : cfgTitle, headings);
                                }];
                            } else {
                                startPagination(cfgTitle, headings);
                            }
                        };

                        // 1. Collect heading positions (if outline requested).
                        if (includeOutline) {
                            [job.web evaluateJavaScript:kHeadingsJS
                                      completionHandler:^(id result, NSError* e) {
                                NSArray* headings = [result isKindOfClass:[NSArray class]]
                                                    ? result : @[];
                                trace("collected %lu headings", (unsigned long)headings.count);
                                afterHeadings(headings);
                            }];
                        } else {
                            afterHeadings(@[]);
                        }

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
