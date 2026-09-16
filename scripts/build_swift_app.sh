#!/usr/bin/env bash
set -euo pipefail

# Build the OpenDefendrWatchr .app bundle from the SwiftPM executable.
#
# Usage:
#   ./scripts/build_swift_app.sh
#
# Environment:
#   VERSION=1.2.3               Override the version written into Info.plist.
#                               Defaults to the newest release in CHANGELOG.md.
#   CONFIGURATION=debug         Build debug instead of release.
#   CODESIGN_IDENTITY="..."     Explicit signing identity.
#   SKIP_SIGN=1                 Do not code sign at all (CI / smoke checks).
#
# The bundle is written to dist/OpenDefendrWatchr.app. Installation is a separate
# step (`make install`), so this script never touches /Applications.

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="OpenDefendrWatchr"
BUNDLE_ID="com.opendefendrwatchr.app"
CONFIGURATION="${CONFIGURATION:-release}"
SKIP_SIGN="${SKIP_SIGN:-0}"

version_from_changelog() {
  grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md 2>/dev/null \
    | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/' || true
}

VERSION="${VERSION:-$(version_from_changelog)}"
VERSION="${VERSION:-0.0.0}"

echo "=== Building $APP_NAME $VERSION ($CONFIGURATION) ==="
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BINARY_PATH="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH" >&2
  exit 1
fi

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# AppUpdater ships SwiftPM resources (Sigstore trust roots). The notarization broker copies
# this bundle into Contents/Resources, so local bundles do the same to match its layout.
RESOURCE_BUNDLE="$BIN_DIR/AppUpdater_AppUpdater.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Build failed: resource bundle not found at $RESOURCE_BUNDLE" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"

# Info.plist carries LSUIElement=true, which is what keeps this a menu-bar-only app
# with no Dock icon.
sed "s/__VERSION__/$VERSION/g" "Sources/$APP_NAME/Info.plist" > "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

plutil -lint "$APP_DIR/Contents/Info.plist" > /dev/null
if ! plutil -extract LSUIElement raw "$APP_DIR/Contents/Info.plist" | grep -q '^true$'; then
  echo "Info.plist is missing LSUIElement=true; the app would show a Dock icon." >&2
  exit 1
fi

find_signing_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CODESIGN_IDENTITY"
    return 0
  fi
  local identities label identity
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for label in "Apple Development" "Developer ID Application"; do
    identity="$(printf '%s\n' "$identities" | grep "$label" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
    if [[ -n "$identity" ]]; then
      printf '%s\n' "$identity"
      return 0
    fi
  done
  return 1
}

if [[ "$SKIP_SIGN" == "1" ]]; then
  echo "Skipping code signing"
else
  IDENTITY="$(find_signing_identity || true)"
  if [[ -n "$IDENTITY" ]]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP_DIR"
  else
    # Ad-hoc signing keeps a stable-enough identity for UserDefaults and
    # notification permissions on a single machine.
    echo "No signing identity found; ad-hoc signing instead."
    codesign --force --sign - "$APP_DIR"
  fi
  codesign --verify --verbose=2 "$APP_DIR"
fi

echo "Bundle: $APP_DIR"
echo "Bundle id: $BUNDLE_ID"
echo "=== Build complete ==="
