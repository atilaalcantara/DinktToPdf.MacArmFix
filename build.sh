#!/usr/bin/env bash
# build.sh — produces a single self-contained libwkhtmltox.dylib for macOS arm64.
#   (DinkToPdf.MacArmFix — native wkhtmltopdf API shim using WKWebView)
#
# Steps:
#   1. Compile the helper (Objective-C++) into a standalone executable.
#   2. Compile bridge.cpp and link it as a dylib, embedding the helper binary
#      into a __DATA,__helperbin Mach-O segment via the linker.
#
# After building, pack the NuGet with:
#   nuget pack nuget/DinkToPdf.MacArmFix.nuspec

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out"
mkdir -p "$OUT"

ARCH="${ARCH:-arm64}"
CXX="${CXX:-clang++}"
SDK="$(xcrun --show-sdk-path)"

COMMON_CXXFLAGS=(
  -std=c++17
  -O2
  -arch "$ARCH"
  -fobjc-arc
  -fvisibility=hidden
  -isysroot "$SDK"
  -mmacosx-version-min=11.0
)

echo "==> [1/2] Building helper executable"
"$CXX" -ObjC++ "${COMMON_CXXFLAGS[@]}" \
  -framework WebKit -framework AppKit -framework Foundation -framework PDFKit \
  -o "$OUT/wkhtmltox-helper" \
  "$SRC/helper.mm"
strip -x "$OUT/wkhtmltox-helper" || true
ls -lh "$OUT/wkhtmltox-helper"

echo "==> [2/2] Building libwkhtmltox.dylib with embedded helper"
"$CXX" "${COMMON_CXXFLAGS[@]}" \
  -shared \
  -install_name @rpath/libwkhtmltox.dylib \
  -Wl,-sectcreate,__DATA,__helperbin,"$OUT/wkhtmltox-helper" \
  -framework Foundation \
  -o "$OUT/libwkhtmltox.dylib" \
  "$SRC/bridge.cpp"
ls -lh "$OUT/libwkhtmltox.dylib"

echo
echo "Done."
echo "  Helper executable : $OUT/wkhtmltox-helper"
echo "  Final dylib       : $OUT/libwkhtmltox.dylib"
echo
echo "To pack NuGet: nuget pack nuget/DinkToPdf.MacArmFix.nuspec"
