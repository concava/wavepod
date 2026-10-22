#!/bin/zsh
# Builds a release .dmg (docs/decisions/0005). Each signing stage runs only when its inputs are set, so the same script
# makes an ad-hoc test build on any Mac and a notarized release in CI.
#
#   VERSION=0.2.0 tools/release.sh
#
# Inputs (environment):
#   VERSION              required, e.g. 0.2.0 (MARKETING_VERSION)
#   BUILD                CFBundleVersion, default 1; must grow with every release for Sparkle
#   SPARKLE_PUBLIC_KEY   EdDSA public key from Sparkle's generate_keys; without it updates stay off in the build
#   DEVELOPER_ID         signing identity, e.g. "Developer ID Application: Name (TEAMID)"; without it: ad hoc
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#                        App Store Connect API key for notarytool; needs DEVELOPER_ID
#
# Output: dist/Wavepod-$VERSION.dmg, and the same file as dist/Wavepod.dmg for the README's
#         releases/latest/download/Wavepod.dmg link, which needs one name in every release
set -euo pipefail

: "${VERSION:?set VERSION, e.g. VERSION=0.2.0}"
BUILD="${BUILD:-1}"
cd "${0:A:h}/.."

DD=build/release
DMG="dist/Wavepod-$VERSION.dmg"

xcodegen generate --quiet
xcodebuild -project wavepod.xcodeproj -scheme wavepod -configuration Release -derivedDataPath "$DD" -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}" \
  build
# The app is named by PRODUCT_NAME in project.yml.
APP="$(find "$DD/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)"
[[ -d "$APP" ]] || { echo "No .app in $DD/Build/Products/Release" >&2; exit 1; }

# wavepod is not sandboxed, so Sparkle's XPC services are unused (Sparkle's docs allow removing them).
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  # Re-sign inside out with the hardened runtime and a secure timestamp. No entitlements: the goal in 0005 is none.
  sign() { codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"; }
  sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  sign "$sparkle/Versions/B/Autoupdate"
  sign "$sparkle/Versions/B/Updater.app"
  sign "$sparkle"
  for dylib in "$APP"/Contents/Frameworks/*.dylib(N); do sign "$dylib"; done
  sign "$APP/Contents/XPCServices/WavepodEngine.xpc"
  sign "$APP/Contents/MacOS/wavepod-feeds"
  sign "$APP"
else
  echo "warning: no DEVELOPER_ID; the app stays ad-hoc signed (testing only, Gatekeeper will block it)" >&2
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

mkdir -p dist
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname Wavepod -srcfolder "$staging" -fs HFS+ -format UDZO "$DMG"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  fi
fi
cp -f "$DMG" dist/Wavepod.dmg

echo "$DMG"
