#!/usr/bin/env bash
set -euo pipefail

# Executable / Swift target name (no spaces — must match Package.swift + Info.plist CFBundleExecutable)
BIN_NAME="FreeMacMonitor"
# User-facing .app bundle name (spaces OK; shown in Finder)
BUNDLE="Free Mac Monitor.app"

echo "=== Building ${BIN_NAME} ==="
swift build -c release

BINARY=".build/release/${BIN_NAME}"
if [ ! -f "${BINARY}" ]; then
    echo "ERROR: binary not found at ${BINARY}"
    exit 1
fi

echo "=== Assembling ${BUNDLE} ==="
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${BINARY}"        "${BUNDLE}/Contents/MacOS/${BIN_NAME}"
cp "Info.plist"       "${BUNDLE}/Contents/"

# Copy web resources if they exist
if [ -d "Sources/FreeMacMonitor/Resources" ]; then
    cp -R Sources/FreeMacMonitor/Resources/ "${BUNDLE}/Contents/Resources/"
fi

# Bundle the app icon (generated offline by scripts/make_icon.swift + iconutil)
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo ""
echo "=== Done: ${BUNDLE} ==="
echo "  Launch:                  open \"${BUNDLE}\""
echo "  If Gatekeeper blocks:    xattr -cr \"${BUNDLE}\" && open \"${BUNDLE}\""
