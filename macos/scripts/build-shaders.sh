#!/bin/sh
# Precompiles the embedded shader source into build/default.metallib so
# the app skips the runtime compile at startup. Needs Xcode's Metal
# toolchain (xcodebuild -downloadComponent MetalToolchain). Without it
# the app compiles the shader at runtime instead, and this script says so.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
# Extract the shader text between the triple quotes in Shaders.swift.
awk '/public static let source = """/{f=1; next} /^    """/{f=0} f' Sources/TermKit/Shaders.swift \
    | sed 's/^    //' > build/cells.metal
if ! [ -s build/cells.metal ] || ! grep -q cell_fragment build/cells.metal; then
    echo "shader extraction produced nothing; check the source markers in Sources/TermKit/Shaders.swift" >&2
    rm -f build/cells.metal build/default.metallib
    exit 1
fi
# Xcode 27 registers a stub metal binary even when the toolchain component
# is absent, so the only reliable check is to attempt the compile.
if ! xcrun -sdk macosx metal -c build/cells.metal -o build/cells.air 2> build/metal.log; then
    echo "metal compiler not available; the app will compile shaders at runtime"
    rm -f build/cells.air build/default.metallib
    exit 0
fi
xcrun -sdk macosx metallib build/cells.air -o build/default.metallib
echo "built build/default.metallib"
