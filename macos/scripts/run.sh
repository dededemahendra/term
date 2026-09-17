#!/bin/sh
# Builds everything and launches the app from its bundle, passing
# through any arguments (for example -e /bin/zsh -l).
set -eu
cd "$(dirname "$0")/.."
scripts/build-core.sh >/dev/null
scripts/build-shaders.sh >/dev/null || true
scripts/bundle.sh >/dev/null
exec build/Term.app/Contents/MacOS/Term "$@"
