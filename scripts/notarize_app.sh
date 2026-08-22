#!/usr/bin/env bash
set -euo pipefail

# Notarise dist/OpenDefendrWatchr.app and staple the ticket.
#
# Usage:
#   NOTARY_PROFILE=<keychain-profile> ./scripts/notarize_app.sh
#
# Environment:
#   NOTARY_PROFILE              notarytool keychain profile, created once with
#                               `xcrun notarytool store-credentials`.
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD
#                               Alternative to NOTARY_PROFILE. Never commit these;
#                               put them in .release.env, which is gitignored.
#   APP_PATH                    Bundle to notarise. Defaults to dist/OpenDefendrWatchr.app.
#
# This script does not build. Run `make bundle-release` first so the bundle is
# signed with Developer ID and a secure timestamp; notarisation rejects anything
# else, and it rejects it slowly, after the upload.

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="OpenDefendrWatchr"
ENV_FILE="${RELEASE_ENV_FILE:-$ROOT_DIR/.release.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

APP_PATH="${APP_PATH:-$ROOT_DIR/dist/$APP_NAME.app}"
ZIP_PATH="${ZIP_PATH:-$ROOT_DIR/dist/$APP_NAME-macos.zip}"
SUBMISSION_DIR="$ROOT_DIR/.build/notary-submissions/$$-${RANDOM}"
SUBMISSION_ZIP="$SUBMISSION_DIR/$APP_NAME.zip"

cleanup() {
  rm -f -- "$SUBMISSION_ZIP"
  rmdir -- "$SUBMISSION_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH. Run 'make bundle-release' first." >&2
  exit 1
fi

# Fail here rather than after a multi-minute upload. Read the signature once:
# piping codesign into `grep -q` would trip pipefail via SIGPIPE and report a
# false negative.
signature_info="$(codesign -dvv "$APP_PATH" 2>&1 || true)"
authority="$(printf '%s\n' "$signature_info" | grep '^Authority=' | head -1 || true)"
if [[ "$authority" != *"Developer ID Application"* ]]; then
  echo "Bundle is signed with: ${authority:-<unsigned>}" >&2
  echo "Notarisation requires 'Developer ID Application'. Run 'make bundle-release'." >&2
  exit 1
fi
if ! printf '%s\n' "$signature_info" | grep -q '^Timestamp='; then
  echo "Bundle has no secure timestamp; notarisation would reject it." >&2
  echo "Run 'make bundle-release' (DISTRIBUTION=1) to sign with --timestamp." >&2
  exit 1
fi

mkdir -p "$(dirname "$ZIP_PATH")" "$SUBMISSION_DIR"
rm -f -- "$ZIP_PATH" "$ZIP_PATH.sha256"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
  missing=()
  for variable in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [[ -z "${!variable:-}" ]]; then
      missing+=("$variable")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Set NOTARY_PROFILE, or provide ${missing[*]}." >&2
    exit 1
  fi
  xcrun notarytool submit "$SUBMISSION_ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# The real acceptance test: what Gatekeeper says on a machine that has never
# seen this build.
spctl --assess --type execute --verbose=2 "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(
  cd "$(dirname "$ZIP_PATH")"
  zip_name="$(basename "$ZIP_PATH")"
  shasum -a 256 "$zip_name" > "$zip_name.sha256"
  shasum -a 256 -c "$zip_name.sha256"
)

echo "Notarised and stapled: $APP_PATH"
echo "ZIP: $ZIP_PATH"
echo "Checksum: $ZIP_PATH.sha256"
