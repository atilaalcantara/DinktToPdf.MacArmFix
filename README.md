# DinkToPdfWebKitBridge

Drop-in `libwkhtmltox.dylib` for **macOS arm64** (Apple Silicon) so .NET projects
that depend on [DinkToPdf](https://github.com/rdvojmoc/DinkToPdf) can render
PDFs natively on M1/M2/M3 Macs without spinning up an x86 container.

## Como foi feito

Este projeto **não usa nenhum código do wkhtmltopdf**. É uma reimplementação do zero que expõe a mesma API C pública (`wkhtmltopdf_convert` e funções relacionadas) que o wkhtmltopdf original expõe — o DinkToPdf chama essas funções via P/Invoke sem perceber a diferença.

### Tecnologias utilizadas

| Componente | Tecnologia |
|---|---|
| Shim da API C | C++17 (`bridge.cpp`) |
| Renderização HTML | `WKWebView` (WebKit nativo do macOS) |
| Geração de PDF | `CGPDFContext` + `NSPrintOperation` (CoreGraphics / AppKit) |
| Paginação | JavaScript (`scrollHeight`) + `WKPDFConfiguration.rect` |
| Linguagem do helper | Objective-C++ (`helper.mm`) |
| Build | `clang++` via `build.sh` |

### Por que não usa o wkhtmltopdf

O wkhtmltopdf usa Qt WebKit, que não tem suporte oficial para macOS ARM64. Em vez de portar ou emular, este projeto usa o **WebKit do próprio sistema operacional** — a mesma engine de renderização do Safari — que já está disponível nativamente em todos os Macs com Apple Silicon.

### Unidades suportadas na conversão de tamanho

Margens e dimensões de página são convertidas para pontos PDF:

| Unidade | Conversão |
|---|---|
| `mm` | `× 72 / 25.4` |
| `cm` | `× 72 / 2.54` |
| `in` | `× 72` |
| `px` | `× 72 / 96` |
| `pt` | `× 1` |

Tamanho padrão: **A4** (595 × 842 pt) com margens de 36 pt em todos os lados.

## Architecture

`DinkToPdf` calls `wkhtmltopdf_convert` from a background worker thread. macOS
WebKit (`WKWebView`) refuses to initialize off the main thread (hard
`RELEASE_ASSERT(isMainThread())`). To bypass that without changing the public
DinkToPdf API, this shim runs the rendering in a separate process:

```
[.NET app] → DinkToPdf P/Invoke → libwkhtmltox.dylib
                                          │
                                  fork+exec on first call
                                          ▼
                              wkhtmltox-helper (own main thread)
                              WKWebView + NSPrintOperation → PDF
```

The helper executable is **embedded inside the dylib** (Mach-O segment
`__DATA,__helperbin`) and extracted to a temp file the first time it's used —
end users only need to ship one file: `libwkhtmltox.dylib`.

## Build

```bash
./build.sh
```

Produces `out/libwkhtmltox.dylib`.

## Test

```bash
cp out/libwkhtmltox.dylib test/runtimes/osx-arm64/native/
cd test
dotnet run -r osx-arm64
```

A `complex-dinktopdf-arm-test.pdf` file should appear next to the test binary.

## Layout

- `src/helper.mm` — Cocoa helper executable (WKWebView + NSPrintOperation).
- `src/bridge.cpp` — wkhtmltopdf C API shim, manages helper subprocess.
- `build.sh` — compiles helper, then dylib with embedded helper segment.
- `test/` — minimal DinkToPdf consumer used to validate end-to-end.

## Debugging

Set `WKHTMLTOPDF_SHIM_LOG=/tmp/shim.log` to enable verbose API tracing inside
the dylib. The helper prints fatal errors to stderr.
