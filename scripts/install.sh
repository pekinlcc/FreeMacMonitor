#!/usr/bin/env bash
#
# Free Mac Monitor — one-shot installer
#
#   curl -fsSL https://raw.githubusercontent.com/pekinlcc/freemacmonitor/main/scripts/install.sh | bash
#
# Optional: pin a specific release tag
#   curl -fsSL ... | bash -s v1.0.0
#
# Honours INSTALL_DIR (default: /Applications)

set -euo pipefail

REPO="pekinlcc/freemacmonitor"
APP_NAME="Free Mac Monitor.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
say()      { printf '→ %s\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
    c_red "This installer is macOS-only."
    exit 1
fi

TAG="${1:-}"
if [ -z "${TAG}" ]; then
    say "Resolving latest release tag"
    TAG="$(
        curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
            | head -1
    )"
fi

if [ -z "${TAG}" ]; then
    c_red "Could not determine release tag. Pass one explicitly: install.sh v1.0.0"
    exit 1
fi

ZIP="Free-Mac-Monitor-${TAG}.zip"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIP}"

say "Target:    ${INSTALL_DIR}/${APP_NAME}"
say "Release:   ${TAG}"
say "Download:  ${URL}"

TMP="$(mktemp -d -t fmm)"
trap 'rm -rf "${TMP}"' EXIT

curl -fL --progress-bar -o "${TMP}/${ZIP}" "${URL}"

# Verify checksum if .sha256 is available on the release
SHA_URL="${URL}.sha256"
if curl -fsSL -o "${TMP}/${ZIP}.sha256" "${SHA_URL}" 2>/dev/null; then
    say "Verifying SHA-256"
    EXPECTED="$(awk '{print $1}' "${TMP}/${ZIP}.sha256")"
    ACTUAL="$(shasum -a 256 "${TMP}/${ZIP}" | awk '{print $1}')"
    if [ "${EXPECTED}" != "${ACTUAL}" ]; then
        c_red "Checksum mismatch:"
        c_red "  expected ${EXPECTED}"
        c_red "  actual   ${ACTUAL}"
        exit 1
    fi
    c_green "✓ checksum OK"
fi

say "Unpacking"
mkdir -p "${TMP}/out"
ditto -x -k "${TMP}/${ZIP}" "${TMP}/out"

APP_SRC="${TMP}/out/${APP_NAME}"
if [ ! -d "${APP_SRC}" ]; then
    APP_SRC="$(find "${TMP}/out" -maxdepth 2 -type d -name '*.app' | head -1)"
fi
if [ ! -d "${APP_SRC}" ]; then
    c_red ".app bundle not found inside ${ZIP}"
    exit 1
fi

say "Removing quarantine attribute"
xattr -cr "${APP_SRC}" || true

TARGET="${INSTALL_DIR}/${APP_NAME}"
if [ -e "${TARGET}" ]; then
    say "Replacing existing install at ${TARGET}"
    # Attempt to quit a running copy so the file can be replaced.
    osascript -e 'tell application "Free Mac Monitor" to quit' >/dev/null 2>&1 || true
    sleep 1
    if ! rm -rf "${TARGET}" 2>/dev/null; then
        sudo rm -rf "${TARGET}"
    fi
fi

say "Installing to ${INSTALL_DIR}"
if ! cp -R "${APP_SRC}" "${INSTALL_DIR}/" 2>/dev/null; then
    c_yellow "   (${INSTALL_DIR} requires sudo)"
    sudo cp -R "${APP_SRC}" "${INSTALL_DIR}/"
fi

# Re-strip quarantine on the installed copy (cp can carry it over on some setups).
xattr -cr "${TARGET}" || sudo xattr -cr "${TARGET}" || true

say "Launching"
open "${TARGET}"

c_green "✓ Free Mac Monitor ${TAG} is installed and running."
c_green "  Look for the >> icon in your menu bar."
echo
echo "  If macOS still refuses to open it:"
echo "    System Settings → Privacy & Security → scroll down → 'Open Anyway'"
echo "  Or right-click the app in Finder and choose Open."
