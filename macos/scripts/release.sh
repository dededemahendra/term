#!/bin/sh
# Universal release: fat core library, universal binary, signed and
# notarised bundle, and a dmg. Signing and notarisation run only when the
# environment provides them:
#   TERM_SIGN_IDENTITY   Developer ID Application certificate name
#   TERM_NOTARY_PROFILE  notarytool keychain profile name
# Without them the bundle is ad hoc signed and the dmg still builds.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/TermKit/Version.swift)
scripts/build-core.sh --universal
scripts/build-shaders.sh || true
scripts/bundle.sh --universal
APP=build/Term.app
if [ -n "${TERM_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$TERM_SIGN_IDENTITY" "$APP"
fi
rm -rf build/dmg && mkdir -p build/dmg && cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
DMG="build/Term-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Term" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
if [ -n "${TERM_SIGN_IDENTITY:-}" ] && [ -n "${TERM_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$TERM_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
# Put the arm64 archive back so development builds do not link the fat one.
scripts/build-core.sh >/dev/null
echo "built $DMG"
