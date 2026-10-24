#!/usr/bin/env bash
# Build OrkaIMessageGateway.app into .build/app.
#
# Usage: scripts/build-app.sh [release|debug]
# GATEWAY_SIGNING selects signing: dev (default, an Apple Development
# certificate, else ad hoc), adhoc, developer-id, or unsigned. APP_IDENTITY
# overrides the certificate.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

CONF=${1:-release}
SIGNING_MODE=${GATEWAY_SIGNING:-dev}
APP_NAME="OrkaIMessageGateway"
DISPLAY_NAME="Orka iMessage Gateway"
BUNDLE_ID="ai.orka.gateway-imessage"
APP_BUNDLE="$ROOT/.build/app/$APP_NAME.app"
ENTITLEMENTS="$ROOT/Resources/$APP_NAME.entitlements"

echo "Building $APP_NAME ($CONF)..."
swift build -c "$CONF" --product "$APP_NAME"
BIN_DIR=$(swift build -c "$CONF" --show-bin-path)
# Swift Build's resource accessors look in Contents/Resources. The older
# SwiftPM build system instead embeds the absolute build path, so its app
# would crash once installed anywhere else.
if strings "$BIN_DIR/$APP_NAME" | grep -qE "^$ROOT/\.build/.*\.bundle$"; then
  echo "ERROR: this toolchain locates resource bundles by build path; build with Xcode 27 or later" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
printf 'APPL????' >"$APP_BUNDLE/Contents/PkgInfo"

# SwiftPM resource bundles, such as PhoneNumberKit's metadata, load from
# Contents/Resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  [[ "$(basename "$bundle")" == *Tests.bundle ]] && continue
  cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done
shopt -u nullglob

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
cat >"$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Orka iMessage Gateway sends your agent's replies through Messages.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Sertac Ozercan. MIT License.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>OrkaGitCommit</key>
    <string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

case "$SIGNING_MODE" in
  unsigned | none)
    echo "Skipping code signing."
    ;;
  adhoc)
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
    ;;
  dev | development)
    identity=${APP_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}
    if [[ -z "$identity" ]]; then
      echo "WARN: no Apple Development certificate; signing ad hoc. macOS forgets permissions after each rebuild." >&2
      identity="-"
    fi
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$identity" "$APP_BUNDLE"
    ;;
  developer-id | release)
    identity=${APP_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}
    if [[ -z "$identity" ]]; then
      echo "ERROR: no Developer ID Application certificate" >&2
      exit 1
    fi
    codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$identity" "$APP_BUNDLE"
    ;;
  *)
    echo "ERROR: unknown GATEWAY_SIGNING mode $SIGNING_MODE (dev, adhoc, developer-id, unsigned)" >&2
    exit 1
    ;;
esac
if [[ "$SIGNING_MODE" != unsigned && "$SIGNING_MODE" != none ]]; then
  codesign --verify --strict "$APP_BUNDLE"
fi

echo "Built $APP_BUNDLE (${MARKETING_VERSION} build ${BUILD_NUMBER}, ${GIT_COMMIT})"
