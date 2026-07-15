#!/usr/bin/env bash
#
# build-macos.sh — one-command macOS release for Audiobooks.
#
# Exports the Godot project, code-signs it with the Developer ID cert,
# notarizes and staples the .app, then builds a matching .dmg and .zip.
# The result is fully Gatekeeper-clean: opens on any Mac, even offline.
#
# Prerequisites (one-time setup):
#   - Godot 4.7.x on PATH with matching export templates installed
#   - "Developer ID Application: Alice Easter (552AB2MLSJ)" in the login keychain
#   - Notary credentials stored:
#       xcrun notarytool store-credentials "audiobooks-notary" \
#         --apple-id "<apple-id>" --team-id "552AB2MLSJ"
#
# Usage:
#   ./build-macos.sh            # version read from export_presets.cfg
#   ./build-macos.sh 1.2.0      # override version for the artifact filenames
#
set -euo pipefail

# --- config ---------------------------------------------------------------
PRESET="macOS"
IDENTITY="Developer ID Application: Alice Easter (552AB2MLSJ)"
NOTARY_PROFILE="audiobooks-notary"
VOLNAME="Audiobooks"
OUT_DIR="dist/macos"
APP_PATH="$OUT_DIR/audiobooks.app"

# --- locate project root --------------------------------------------------
cd "$(dirname "$0")"

# --- version --------------------------------------------------------------
if [[ $# -ge 1 ]]; then
  VERSION="$1"
else
  VERSION="$(sed -n 's/^application\/short_version="\(.*\)"/\1/p' export_presets.cfg | head -1)"
fi
if [[ -z "${VERSION:-}" ]]; then
  echo "error: no version given and none found in export_presets.cfg" >&2
  exit 1
fi

DMG_PATH="$OUT_DIR/Audiobooks-$VERSION.dmg"
ZIP_PATH="$OUT_DIR/Audiobooks-$VERSION.zip"

echo "==> Building Audiobooks $VERSION"

# --- preflight ------------------------------------------------------------
command -v godot >/dev/null || { echo "error: godot not on PATH" >&2; exit 1; }
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if [[ "$IDENTITIES" != *"$IDENTITY"* ]]; then
  echo "error: signing identity not found: $IDENTITY" >&2
  exit 1
fi
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "error: notary profile '$NOTARY_PROFILE' not stored (see header)" >&2; exit 1; }

# --- 1. export + sign -----------------------------------------------------
echo "==> Exporting and signing (.app)"
mkdir -p "$OUT_DIR"
rm -rf "$APP_PATH"
godot --headless --export-release "$PRESET" "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
# Capture first, then match: `... | grep -q` would SIGPIPE codesign and, under
# `set -o pipefail`, fail the pipeline even on a match (false negative).
SIG_INFO="$(codesign -dvv "$APP_PATH" 2>&1 || true)"
if [[ "$SIG_INFO" != *"TeamIdentifier=552AB2MLSJ"* ]]; then
  echo "error: app is not signed with the expected Developer ID (ad-hoc?)" >&2
  exit 1
fi

# --- 2. notarize + staple the app ----------------------------------------
echo "==> Notarizing .app (this can take a few minutes)"
NOTARIZE_ZIP="$(mktemp -d)/audiobooks-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$NOTARIZE_ZIP"
xcrun stapler staple "$APP_PATH"

# --- 3. package .zip (from the stapled app) -------------------------------
echo "==> Packaging $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# --- 4. build + sign + notarize + staple the .dmg -------------------------
echo "==> Building $DMG_PATH"
STAGE="$(mktemp -d)"
ditto "$APP_PATH" "$STAGE/Audiobooks.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE"

echo "==> Signing and notarizing .dmg"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

# --- 5. final verification ------------------------------------------------
echo "==> Final Gatekeeper check"
spctl -a -vvv -t exec "$APP_PATH"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"

echo
echo "✅ Done. Notarized & stapled artifacts:"
ls -lh "$DMG_PATH" "$ZIP_PATH"
