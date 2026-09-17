#!/bin/sh
# Builds the Rust core as a release static library into ../target/release,
# which Package.swift links. Pass --universal to also build x86_64 and
# produce a fat archive for release packaging.
set -eu
cd "$(dirname "$0")/../.."
cargo build -p termcore --release
# A stale fat archive would shadow the fresh arm64 build.
rm -rf target/universal
if [ "${1:-}" = "--universal" ]; then
    rustup target add x86_64-apple-darwin >/dev/null
    cargo build -p termcore --release --target x86_64-apple-darwin
    cargo build -p termcore --release --target aarch64-apple-darwin
    mkdir -p target/universal
    lipo -create target/aarch64-apple-darwin/release/libtermcore.a \
        target/x86_64-apple-darwin/release/libtermcore.a \
        -output target/universal/libtermcore.a
    echo "built target/universal/libtermcore.a"
fi
echo "built target/release/libtermcore.a"
