#!/bin/sh
# Builds bin/ClaudePiP as a universal binary (Apple Silicon + Intel). Needs Xcode command line tools.
set -e
cd "$(dirname "$0")"
t=$(mktemp -d)
for a in arm64 x86_64; do swiftc -O -target "$a-apple-macos12" src/pip.swift -o "$t/$a"; done
lipo -create "$t/arm64" "$t/x86_64" -output bin/ClaudePiP
codesign -s - --force bin/ClaudePiP
rm -r "$t"
