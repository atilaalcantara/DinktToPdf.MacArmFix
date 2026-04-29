# DinkToPdf.MacArmFix

Native `libwkhtmltox.dylib` shim for **macOS Apple Silicon (arm64)** — makes [DinkToPdf](https://github.com/rdvojmoc/DinkToPdf) work natively on M1/M2/M3/M4 Macs without running an x86 container.

## Install

```bash
dotnet add package DinkToPdf.MacArmFix
dotnet add package DinkToPdf
```

That's it. The native library is automatically placed in `runtimes/osx-arm64/native/` at build time.

## Why this exists

`DinkToPdf` relies on `libwkhtmltox`, which is built on Qt WebKit. Qt WebKit has no official macOS ARM64 support, so the official binaries crash or simply don't exist on Apple Silicon.

This project **reimplements the exact same wkhtmltopdf C public API** (`wkhtmltopdf_convert` and related functions) using native macOS technologies — DinkToPdf calls these functions via P/Invoke and never notices the difference.

| Component | Technology |
|---|---|
| C API shim | C++17 (`bridge.cpp`) |
| HTML rendering | `WKWebView` (macOS native WebKit — same engine as Safari) |
| PDF generation | `CGPDFContext` + `NSPrintOperation` (CoreGraphics / AppKit) |
| Pagination | JavaScript (`scrollHeight`) + `WKPDFConfiguration.rect` |
| Helper process | Objective-C++ (`helper.mm`) |
| Build | `clang++` via `build.sh` |

## Architecture

`DinkToPdf` calls `wkhtmltopdf_convert` from a background worker thread. macOS WebKit (`WKWebView`) refuses to initialize off the main thread (`RELEASE_ASSERT(isMainThread())`). To work around this without modifying DinkToPdf, the shim runs rendering in a separate process:

```
[.NET app] → DinkToPdf P/Invoke → libwkhtmltox.dylib
                                          │
                                  fork+exec on first call
                                          ▼
                              wkhtmltox-helper (own main thread)
                              WKWebView + NSPrintOperation → PDF
```

The helper executable is **embedded inside the dylib** (Mach-O segment `__DATA,__helperbin`) and extracted to a temp file on first use — end users ship only one file: `libwkhtmltox.dylib`.

## Supported API

| Function / Setting | Support |
|---|---|
| `wkhtmltopdf_convert`, `get_output`, `add_object` | ✅ |
| `size.paperSize` (A3, A4, A5, Letter, Legal) | ✅ |
| `size.width` / `size.height` (custom) | ✅ |
| `orientation` (Portrait / Landscape) | ✅ |
| `margin.top/right/bottom/left` | ✅ |
| `out` (save to file) | ✅ |
| `web.enableJavascript`, `web.loadImages`, `web.printBackground` | ✅ |
| Text headers/footers (`header.left/center/right`, `footer.*`) | ✅ |
| Header/footer variables (`[page]`, `[toPage]`, `[date]`, `[time]`, `[title]`) | ✅ |
| `header.fontSize`, `header.fontName`, `header.line`, `header.spacing` | ✅ |
| `outline` (PDF bookmarks via `h1`–`h6`) | ✅ |
| `outlineDepth` | ✅ |
| `documentTitle` (global setting) | ✅ |

### Known limitations

| Feature | Status | Reason |
|---|---|---|
| `header.htmlUrl` / `footer.htmlUrl` | ❌ Not implemented | Requires a second `WKWebView` per page with JS variable substitution. PRs welcome. |
| TOC (automatic table of contents) | ❌ Not implemented | Requires an extra rendering pass. PRs welcome. |
| `page.includeInOutline` (per object) | ⚠️ Ignored | Use the global `outline` setting instead. |
| Multiple HTML objects per conversion | ⚠️ Partial | Objects are concatenated into a single HTML; header/footer settings from the first object apply to all. |

### Display session requirement

This project requires an **active graphical user session on macOS** (even with the screen locked). It does not work on headless Linux servers or Docker containers, as `WKWebView` requires an NSApp with a run loop and an off-screen window.

For CI, use macOS runners (e.g. `macos-latest` on GitHub Actions), which have a graphical session available.

## Supported size units

Margins and page dimensions are converted to PDF points:

| Unit | Conversion |
|---|---|
| `mm` | `× 72 / 25.4` |
| `cm` | `× 72 / 2.54` |
| `in` | `× 72` |
| `px` | `× 72 / 96` |
| `pt` | `× 1` |

Default page size: **A4** (595 × 842 pt) with 36 pt margins on all sides.

## Build from source

```bash
./build.sh
```

Produces `out/libwkhtmltox.dylib`.

### Pack NuGet

```bash
./build.sh
nuget pack nuget/DinkToPdf.MacArmFix.nuspec
```

### Test

```bash
cp out/libwkhtmltox.dylib test/runtimes/osx-arm64/native/
cd test && dotnet run -r osx-arm64
```

A `complex-dinktopdf-arm-test.pdf` should appear next to the test binary.

## Repository layout

```
src/
  bridge.cpp       — wkhtmltopdf C API shim, manages helper subprocess
  helper.mm        — Cocoa helper (WKWebView + NSPrintOperation)
nuget/
  DinkToPdf.MacArmFix.nuspec  — NuGet package definition
test/
  DinkToPdf.MacArmFix.Test.csproj
  Program.cs       — end-to-end smoke test
  assets/          — sample HTML
build.sh           — compiles helper then dylib with embedded helper segment
```

## Debugging

Set `WKHTMLTOPDF_SHIM_LOG=/tmp/shim.log` to enable verbose API tracing inside the dylib. The helper prints fatal errors to stderr.

## License

MIT
