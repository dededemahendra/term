#!/bin/sh
# Precompiles the embedded shader source into build/default.metallib so
# the app skips the runtime compile at startup. Needs Xcode's Metal
# toolchain (xcodebuild -downloadComponent MetalToolchain). Without it
# the app compiles the shader at runtime instead, and this script says so.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    echo "metal compiler not available; the app will compile shaders at runtime"
    exit 0
fi
# Extract the shader text between the triple quotes in Shaders.swift.
awk '/public static let source = """/{f=1; next} /^    """/{f=0} f' Sources/TermKit/Shaders.swift \
    | sed 's/^    //' > build/cells.metal
xcrun -sdk macosx metal -c build/cells.metal -o build/cells.air
xcrun -sdk macosx metallib build/cells.air -o build/default.metallib
echo "built build/default.metallib"
