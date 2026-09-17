#!/bin/sh
# Builds the release binary and assembles build/Term.app with an ad hoc
# signature, so it launches without prompts. A precompiled shader
# library is included when scripts/build-shaders.sh produced one.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/TermKit/Version.swift)
if [ "${1:-}" = "--universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY=.build/apple/Products/Release/Term
else
    swift build -c release
    BINARY=.build/release/Term
fi
APP=build/Term.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Term"
if [ -f build/default.metallib ]; then
    cp build/default.metallib "$APP/Contents/Resources/default.metallib"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.term.app</string>
    <key>CFBundleName</key><string>Term</string>
    <key>CFBundleDisplayName</key><string>Term</string>
    <key>CFBundleExecutable</key><string>Term</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null
echo "built $APP"
