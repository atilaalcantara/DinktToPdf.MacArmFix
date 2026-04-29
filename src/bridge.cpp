// bridge.cpp — wkhtmltopdf C API shim for macOS ARM64
//
// Drop-in replacement for libwkhtmltox.dylib that DinkToPdf can use on Apple
// Silicon. Conversion is done by spawning a sidecar helper process that uses
// WKWebView + NSPrintOperation (the system WebKit engine). The helper binary
// is embedded inside this dylib's __DATA,__helperbin segment, extracted to
// a temp file at first use, and exec'd. The user only ships ONE file.
//
// Build: clang++ links bridge.cpp normally and uses ld(1) -sectcreate to
// inject the prebuilt helper executable into the resulting dylib.

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>

namespace {

// ---- wkhtmltopdf-style data model ----------------------------------------

struct Settings {
    std::map<std::string, std::string> values;
};

struct Object {
    Settings* settings = nullptr;
    std::string data;
};

struct Converter {
    Settings* global = nullptr;
    std::vector<Object> objects;
    std::vector<unsigned char> output;
    std::string error;
    void (*warning_callback)(void*, const char*)  = nullptr;
    void (*error_callback)(void*, const char*)    = nullptr;
    void (*phase_changed_callback)(void*)         = nullptr;
    void (*progress_changed_callback)(void*, int) = nullptr;
    void (*finished_callback)(void*, int)         = nullptr;
};

std::mutex g_mutex;

void log_line(const std::string& msg) {
    const char* enabled = std::getenv("WKHTMLTOPDF_SHIM_LOG");
    if (!enabled || !*enabled) return;
    std::ofstream f(enabled, std::ios::app);
    f << msg << '\n';
}

std::string get_setting(const Settings* s, const std::string& key) {
    if (!s) return {};
    auto it = s->values.find(key);
    return it == s->values.end() ? std::string{} : it->second;
}

std::string compose_html(const Converter* c) {
    if (!c || c->objects.empty())
        return "<!doctype html><html><body></body></html>";
    if (c->objects.size() == 1) return c->objects.front().data;
    std::string h = "<!doctype html><html><body>";
    for (const auto& o : c->objects) {
        h += o.data;
        h += "<div style=\"break-after:page;\"></div>";
    }
    h += "</body></html>";
    return h;
}

// ---- Length / unit helpers (wkhtmltopdf settings -> points) --------------

double parse_length_to_pt(const std::string& v, double fallback) {
    if (v.empty()) return fallback;
    char* endp = nullptr;
    double n = std::strtod(v.c_str(), &endp);
    if (endp == v.c_str()) return fallback;
    while (*endp == ' ') ++endp;
    std::string u = endp;
    if (u == "mm")           return n * 72.0 / 25.4;
    if (u == "cm")           return n * 72.0 / 2.54;
    if (u == "in")           return n * 72.0;
    if (u == "px")           return n * 72.0 / 96.0;
    if (u == "pt" || u.empty()) return n;
    return n;
}

struct PaperSpec {
    double w_pt = 595.0, h_pt = 842.0;
    double mt = 36, mr = 36, mb = 36, ml = 36;
};

PaperSpec resolve_paper(const Settings* s) {
    PaperSpec p;
    std::string ws = get_setting(s, "size.width");
    std::string hs = get_setting(s, "size.height");
    if (!ws.empty() && !hs.empty()) {
        p.w_pt = parse_length_to_pt(ws, 595.0);
        p.h_pt = parse_length_to_pt(hs, 842.0);
    } else {
        std::string paper = get_setting(s, "size.paperSize");
        if      (paper == "A3")     { p.w_pt = 842.0;  p.h_pt = 1191.0; }
        else if (paper == "A5")     { p.w_pt = 420.0;  p.h_pt = 595.0;  }
        else if (paper == "Letter") { p.w_pt = 612.0;  p.h_pt = 792.0;  }
        else if (paper == "Legal")  { p.w_pt = 612.0;  p.h_pt = 1008.0; }
        // default already A4 (595x842)
    }
    if (get_setting(s, "orientation") == "Landscape")
        std::swap(p.w_pt, p.h_pt);

    p.mt = parse_length_to_pt(get_setting(s, "margin.top"),    36.0);
    p.mr = parse_length_to_pt(get_setting(s, "margin.right"),  36.0);
    p.mb = parse_length_to_pt(get_setting(s, "margin.bottom"), 36.0);
    p.ml = parse_length_to_pt(get_setting(s, "margin.left"),   36.0);
    return p;
}

// ---- JSON helpers --------------------------------------------------------

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char buf[8]; std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
        }
    }
    return out;
}

// ---- Embedded helper extraction ------------------------------------------

// Look up "this dylib" mach_header so getsectiondata() can find our embedded
// segment regardless of where the dylib is loaded.
const struct mach_header* this_image_header() {
    Dl_info info{};
    if (dladdr((const void*)&this_image_header, &info) == 0 || !info.dli_fbase)
        return nullptr;
    return (const struct mach_header*)info.dli_fbase;
}

// Path of THIS dylib on disk, used for last-resort fallback (helper sibling).
std::string this_image_path() {
    Dl_info info{};
    if (dladdr((const void*)&this_image_path, &info) == 0 || !info.dli_fname)
        return {};
    return info.dli_fname;
}

// Extract the embedded helper binary to a private file the first time it's
// needed. The file name encodes a hash-ish of the embedded blob's address
// + size so updates of the dylib don't reuse a stale extracted binary.
bool extract_helper(std::string& out_path, std::string& err) {
    static std::mutex extract_mutex;
    static std::string cached_path;
    std::lock_guard<std::mutex> lock(extract_mutex);
    if (!cached_path.empty()) {
        struct stat st{};
        if (::stat(cached_path.c_str(), &st) == 0 && (st.st_mode & S_IXUSR)) {
            out_path = cached_path;
            return true;
        }
        cached_path.clear();
    }

    const struct mach_header_64* mh =
        (const struct mach_header_64*)this_image_header();
    if (!mh) { err = "Could not resolve dylib mach header."; return false; }

    unsigned long size = 0;
    uint8_t* data = getsectiondata(mh, "__DATA", "__helperbin", &size);
    if (!data || size == 0) {
        // Fallback: helper sibling next to dylib (useful for dev/debug builds).
        std::string here = this_image_path();
        size_t slash = here.find_last_of('/');
        std::string dir = (slash == std::string::npos) ? "." : here.substr(0, slash);
        std::string sibling = dir + "/wkhtmltox-helper";
        struct stat st{};
        if (::stat(sibling.c_str(), &st) == 0 && (st.st_mode & S_IXUSR)) {
            cached_path = sibling;
            out_path    = sibling;
            return true;
        }
        err = "Embedded helper not found in __DATA,__helperbin (and no sibling).";
        return false;
    }

    const char* tmp = std::getenv("TMPDIR");
    std::string dir = tmp && *tmp ? tmp : "/tmp";
    if (dir.back() != '/') dir.push_back('/');

    char tmpl[1024];
    std::snprintf(tmpl, sizeof(tmpl),
                  "%swkhtmltox-helper-%lu-XXXXXX",
                  dir.c_str(), (unsigned long)size);
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        err = std::string("mkstemp: ") + std::strerror(errno);
        return false;
    }
    ssize_t written = ::write(fd, data, (size_t)size);
    ::close(fd);
    if (written != (ssize_t)size) {
        ::unlink(tmpl);
        err = "short write extracting helper";
        return false;
    }
    if (::chmod(tmpl, 0700) != 0) {
        ::unlink(tmpl);
        err = std::string("chmod: ") + std::strerror(errno);
        return false;
    }
    cached_path = tmpl;
    out_path    = tmpl;
    return true;
}

// ---- Subprocess helper invocation ----------------------------------------

bool write_all(int fd, const void* buf, size_t n) {
    const uint8_t* p = (const uint8_t*)buf;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = ::write(fd, p + sent, n - sent);
        if (w < 0) { if (errno == EINTR) continue; return false; }
        sent += (size_t)w;
    }
    return true;
}

bool read_all(int fd, void* buf, size_t n) {
    uint8_t* p = (uint8_t*)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = ::read(fd, p + got, n - got);
        if (r < 0) { if (errno == EINTR) continue; return false; }
        if (r == 0) return false;
        got += (size_t)r;
    }
    return true;
}

bool write_u32_be(int fd, uint32_t v) {
    uint8_t b[4] = { (uint8_t)((v>>24)&0xFF), (uint8_t)((v>>16)&0xFF),
                     (uint8_t)((v>>8) &0xFF), (uint8_t)(v & 0xFF) };
    return write_all(fd, b, 4);
}

bool read_u32_be(int fd, uint32_t* out) {
    uint8_t b[4];
    if (!read_all(fd, b, 4)) return false;
    *out = ((uint32_t)b[0]<<24) | ((uint32_t)b[1]<<16) |
           ((uint32_t)b[2]<<8)  |  (uint32_t)b[3];
    return true;
}

// Build JSON config for the helper process.
// Header/footer settings come from the first object's settings (os).
// header.spacing in wkhtmltopdf is a unitless double representing mm.
std::string make_config_json(const PaperSpec& p,
                             const Settings* gs,
                             const Settings* os) {
    auto hdr = [&](const std::string& k) { return get_setting(os, "header." + k); };
    auto ftr = [&](const std::string& k) { return get_setting(os, "footer." + k); };

    auto mm_to_pt = [](const std::string& v, double def) -> double {
        if (v.empty()) return def;
        try { return std::stod(v) * 72.0 / 25.4; } catch (...) { return def; }
    };
    auto str_to_d = [](const std::string& v, double def) -> double {
        if (v.empty()) return def;
        try { return std::stod(v); } catch (...) { return def; }
    };

    bool js     = get_setting(gs, "web.enableJavascript") != "false";
    bool images = get_setting(gs, "web.loadImages")       != "false";
    bool bg     = get_setting(gs, "web.printBackground")  != "false";

    std::string title   = get_setting(gs, "documentTitle");
    std::string hfn     = hdr("fontName"); if (hfn.empty()) hfn = "Helvetica";
    std::string ffn     = ftr("fontName"); if (ffn.empty()) ffn = "Helvetica";
    bool hdr_line       = (hdr("line") == "true" || hdr("line") == "1");
    bool ftr_line       = (ftr("line") == "true" || ftr("line") == "1");

    std::string j;
    j.reserve(1024);
    j += "{";

    auto add_d = [&](const char* key, double val) {
        char tmp[64]; std::snprintf(tmp, sizeof(tmp), "%.6f", val);
        j += '"'; j += key; j += "\":"; j += tmp; j += ',';
    };
    auto add_b = [&](const char* key, bool val) {
        j += '"'; j += key; j += "\":";
        j += val ? "true" : "false"; j += ',';
    };
    auto add_s = [&](const char* key, const std::string& val) {
        j += '"'; j += key; j += "\":\"";
        j += json_escape(val); j += "\",";
    };

    add_d("paper_w_pt",       p.w_pt);
    add_d("paper_h_pt",       p.h_pt);
    add_d("margin_top_pt",    p.mt);
    add_d("margin_right_pt",  p.mr);
    add_d("margin_bottom_pt", p.mb);
    add_d("margin_left_pt",   p.ml);
    add_b("javascript",       js);
    add_b("load_images",      images);
    add_b("print_background", bg);
    add_d("load_timeout_sec", 30.0);

    // Header
    add_s("header_left",       hdr("left"));
    add_s("header_center",     hdr("center"));
    add_s("header_right",      hdr("right"));
    add_d("header_font_size",  str_to_d(hdr("fontSize"), 9.0));
    add_s("header_font_name",  hfn);
    add_b("header_line",       hdr_line);
    add_d("header_spacing_pt", mm_to_pt(hdr("spacing"), 0.0));

    // Footer
    add_s("footer_left",       ftr("left"));
    add_s("footer_center",     ftr("center"));
    add_s("footer_right",      ftr("right"));
    add_d("footer_font_size",  str_to_d(ftr("fontSize"), 9.0));
    add_s("footer_font_name",  ffn);
    add_b("footer_line",       ftr_line);
    add_d("footer_spacing_pt", mm_to_pt(ftr("spacing"), 0.0));

    add_s("document_title", title);

    // Outline (PDF bookmarks from headings). Global settings: outline / outlineDepth.
    bool outline = (get_setting(gs, "outline") == "true");
    int  depth   = 4;
    {
        auto ds = get_setting(gs, "outlineDepth");
        if (!ds.empty()) try { depth = std::stoi(ds); } catch (...) {}
    }
    add_b("outline",       outline);
    add_d("outline_depth", (double)depth);

    if (!j.empty() && j.back() == ',') j.pop_back();
    j += '}';
    return j;
}

bool run_helper(const std::string& html,
                const PaperSpec& paper,
                const Settings* gs,
                const Settings* os,
                std::vector<unsigned char>& out_pdf,
                std::string& err) {
    std::string helper_path;
    if (!extract_helper(helper_path, err)) return false;

    int in_pipe[2];   // dylib -> helper stdin
    int out_pipe[2];  // helper stdout -> dylib
    if (::pipe(in_pipe) < 0)  { err = "pipe(in)";  return false; }
    if (::pipe(out_pipe) < 0) {
        ::close(in_pipe[0]); ::close(in_pipe[1]);
        err = "pipe(out)"; return false;
    }

    pid_t pid = ::fork();
    if (pid < 0) {
        ::close(in_pipe[0]);  ::close(in_pipe[1]);
        ::close(out_pipe[0]); ::close(out_pipe[1]);
        err = std::string("fork: ") + std::strerror(errno);
        return false;
    }
    if (pid == 0) {
        // Child: wire pipes to stdin/stdout, exec helper.
        ::dup2(in_pipe[0],  STDIN_FILENO);
        ::dup2(out_pipe[1], STDOUT_FILENO);
        ::close(in_pipe[0]);  ::close(in_pipe[1]);
        ::close(out_pipe[0]); ::close(out_pipe[1]);
        // Leave stderr connected to parent's stderr so errors are visible
        // when WKHTMLTOPDF_SHIM_LOG isn't set.
        const char* argv[] = { helper_path.c_str(), nullptr };
        ::execv(helper_path.c_str(), (char* const*)argv);
        // execv only returns on failure.
        _exit(127);
    }

    // Parent
    ::close(in_pipe[0]);
    ::close(out_pipe[1]);

    bool ok_write = true;
    {
        std::string cfg = make_config_json(paper, gs, os);
        ok_write &= write_u32_be(in_pipe[1], (uint32_t)cfg.size());
        ok_write &= write_all  (in_pipe[1], cfg.data(), cfg.size());
        ok_write &= write_u32_be(in_pipe[1], (uint32_t)html.size());
        ok_write &= write_all  (in_pipe[1], html.data(), html.size());
    }
    ::close(in_pipe[1]);
    if (!ok_write) {
        ::close(out_pipe[0]);
        ::waitpid(pid, nullptr, 0);
        err = "Failed to send job to helper.";
        return false;
    }

    // Read framed response.
    uint32_t status = 0, len = 0;
    if (!read_u32_be(out_pipe[0], &status) || !read_u32_be(out_pipe[0], &len)) {
        ::close(out_pipe[0]);
        int wstatus = 0; ::waitpid(pid, &wstatus, 0);
        err = "Helper exited without producing output.";
        return false;
    }
    if (len > (256u * 1024u * 1024u)) {
        ::close(out_pipe[0]); ::waitpid(pid, nullptr, 0);
        err = "Helper produced unreasonably large response."; return false;
    }
    std::vector<unsigned char> body(len);
    if (len > 0 && !read_all(out_pipe[0], body.data(), len)) {
        ::close(out_pipe[0]); ::waitpid(pid, nullptr, 0);
        err = "Truncated response from helper."; return false;
    }
    ::close(out_pipe[0]);
    int wstatus = 0; ::waitpid(pid, &wstatus, 0);

    if (status == 1) {
        out_pdf = std::move(body);
        return true;
    }
    err = std::string("Helper failed: ") +
          std::string(body.begin(), body.end());
    return false;
}

bool html_to_pdf(const std::string& html,
                 const Settings* global,
                 const Settings* obj_settings,
                 std::vector<unsigned char>& output,
                 std::string& err) {
    PaperSpec paper = resolve_paper(global);
    return run_helper(html, paper, global, obj_settings, output, err);
}

} // namespace

// ---- wkhtmltopdf C API ----------------------------------------------------

extern "C" {

#define EXPORT __attribute__((visibility("default")))

EXPORT int  wkhtmltopdf_init(int use_graphics)   { (void)use_graphics; return 1; }
EXPORT int  wkhtmltopdf_deinit()                 { return 1; }
EXPORT int  wkhtmltopdf_extended_qt()            { return 0; }
EXPORT const char* wkhtmltopdf_version()         { return "0.12.6 (webkit-helper-arm64)"; }

EXPORT void* wkhtmltopdf_create_global_settings() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return new Settings();
}
EXPORT int  wkhtmltopdf_set_global_setting(void* s, const char* name, const char* value) {
    if (!s || !name) return 0;
    std::lock_guard<std::mutex> lock(g_mutex);
    static_cast<Settings*>(s)->values[name] = value ? value : "";
    log_line(std::string("global ") + name + "=" + (value?value:""));
    return 1;
}
EXPORT int  wkhtmltopdf_get_global_setting(void* s, const char* name, char* value, int valueSize) {
    if (!s||!name||!value||valueSize<=0) return 0;
    std::lock_guard<std::mutex> lock(g_mutex);
    auto& m = static_cast<Settings*>(s)->values;
    auto it = m.find(name);
    if (it == m.end()) return 0;
    std::strncpy(value, it->second.c_str(), (size_t)(valueSize-1));
    value[valueSize-1] = '\0'; return 1;
}
EXPORT void wkhtmltopdf_destroy_global_settings(void* s) {
    if (!s) return;
    std::lock_guard<std::mutex> lock(g_mutex);
    delete static_cast<Settings*>(s);
}

EXPORT void* wkhtmltopdf_create_object_settings() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return new Settings();
}
EXPORT int  wkhtmltopdf_set_object_setting(void* s, const char* name, const char* value) {
    if (!s || !name) return 0;
    std::lock_guard<std::mutex> lock(g_mutex);
    static_cast<Settings*>(s)->values[name] = value ? value : "";
    log_line(std::string("object ") + name + "=" + (value?value:""));
    return 1;
}
EXPORT int  wkhtmltopdf_get_object_setting(void* s, const char* name, char* value, int valueSize) {
    if (!s||!name||!value||valueSize<=0) return 0;
    std::lock_guard<std::mutex> lock(g_mutex);
    auto& m = static_cast<Settings*>(s)->values;
    auto it = m.find(name);
    if (it == m.end()) return 0;
    std::strncpy(value, it->second.c_str(), (size_t)(valueSize-1));
    value[valueSize-1] = '\0'; return 1;
}
EXPORT void wkhtmltopdf_destroy_object_settings(void* s) {
    if (!s) return;
    std::lock_guard<std::mutex> lock(g_mutex);
    delete static_cast<Settings*>(s);
}

EXPORT void* wkhtmltopdf_create_converter(void* gs) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto* c = new Converter();
    c->global = static_cast<Settings*>(gs);
    return c;
}
EXPORT void  wkhtmltopdf_add_object(void* c, void* os, const char* data) {
    if (!c) return;
    std::lock_guard<std::mutex> lock(g_mutex);
    Object o; o.settings = static_cast<Settings*>(os);
    o.data = data ? data : "";
    if (o.data.empty()) o.data = get_setting(o.settings, "page");
    log_line("add_object bytes=" + std::to_string(o.data.size()));
    static_cast<Converter*>(c)->objects.push_back(std::move(o));
}

EXPORT int  wkhtmltopdf_convert(void* converter_ptr) {
    if (!converter_ptr) return 0;
    auto* c = static_cast<Converter*>(converter_ptr);
    std::string html;
    Settings* gs = nullptr;
    const Settings* os = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        c->output.clear(); c->error.clear();
        html = compose_html(c);
        gs   = c->global;
        os   = c->objects.empty() ? nullptr : c->objects.front().settings;
    }
    log_line("convert html_len=" + std::to_string(html.size()));
    if (c->phase_changed_callback)    c->phase_changed_callback(c);
    if (c->progress_changed_callback) c->progress_changed_callback(c, 10);

    std::string err;
    bool ok = html_to_pdf(html, gs, os, c->output, err);

    if (!ok || c->output.empty()) {
        std::lock_guard<std::mutex> lock(g_mutex);
        c->error = err.empty() ? "WebKit helper failed." : err;
        log_line("convert FAILED: " + c->error);
        if (c->error_callback)    c->error_callback(c, c->error.c_str());
        if (c->finished_callback) c->finished_callback(c, 0);
        return 0;
    }

    std::string out;
    { std::lock_guard<std::mutex> lock(g_mutex); out = get_setting(gs, "out"); }
    if (!out.empty() && out != "-") {
        std::ofstream f(out, std::ios::binary);
        f.write(reinterpret_cast<const char*>(c->output.data()),
                (std::streamsize)c->output.size());
    }
    log_line("output bytes=" + std::to_string(c->output.size()));
    if (c->progress_changed_callback) c->progress_changed_callback(c, 100);
    if (c->finished_callback)         c->finished_callback(c, 1);
    return 1;
}

EXPORT int  wkhtmltopdf_get_output(void* c, const unsigned char** data) {
    if (!c||!data) return 0;
    std::lock_guard<std::mutex> lock(g_mutex);
    auto* cc = static_cast<Converter*>(c);
    *data = cc->output.empty() ? nullptr : cc->output.data();
    return (int)cc->output.size();
}
EXPORT void wkhtmltopdf_destroy_converter(void* c) {
    if (!c) return;
    std::lock_guard<std::mutex> lock(g_mutex);
    delete static_cast<Converter*>(c);
}

EXPORT void wkhtmltopdf_set_warning_callback(void* c, void (*cb)(void*, const char*)) {
    if (!c) return; std::lock_guard<std::mutex> lock(g_mutex);
    static_cast<Converter*>(c)->warning_callback = cb;
}
EXPORT void wkhtmltopdf_set_error_callback(void* c, void (*cb)(void*, const char*)) {
    if (!c) return; std::lock_guard<std::mutex> lock(g_mutex);
    static_cast<Converter*>(c)->error_callback = cb;
}
EXPORT void wkhtmltopdf_set_phase_changed_callback(void* c, void (*cb)(void*)) {
    if (!c) return; std::lock_guard<std::mutex> lock(g_mutex);
    static_cast<Converter*>(c)->phase_changed_callback = cb;
}
EXPORT void wkhtmltopdf_set_progress_changed_callback(void* c, void (*cb)(void*, int)) {
    if (!c) return; std::lock_guard<std::mutex> lock(g_mutex);
    static_cast<Converter*>(c)->progress_changed_callback = cb;
}
EXPORT void wkhtmltopdf_set_finished_callback(void* c, void (*cb)(void*, int)) {
    if (!c) return; std::lock_guard<std::mutex> lock(g_mutex);
    static_cast<Converter*>(c)->finished_callback = cb;
}

EXPORT int         wkhtmltopdf_phase_count(void* c)            { (void)c; return 1; }
EXPORT int         wkhtmltopdf_current_phase(void* c)          { (void)c; return 0; }
EXPORT const char* wkhtmltopdf_phase_description(void* c, int p) { (void)c;(void)p; return "Rendering PDF"; }
EXPORT const char* wkhtmltopdf_progress_string(void* c)        { (void)c; return ""; }
EXPORT int         wkhtmltopdf_http_error_code(void* c)        { (void)c; return 0; }

} // extern "C"
