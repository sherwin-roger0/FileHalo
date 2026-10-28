#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
BUNDLE="${1:-../FileHalo.app}"
mkdir -p "$BUNDLE/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/main.swift -o "$BUNDLE/Contents/MacOS/FileHalo" -framework Cocoa -framework SwiftUI -framework PDFKit -framework UniformTypeIdentifiers -framework ImageIO -framework Vision -framework CoreImage -framework ServiceManagement
codesign --force --deep --sign - "$BUNDLE"
