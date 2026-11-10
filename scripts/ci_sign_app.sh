#!/usr/bin/env bash
# Signs the built app with your certificate and profile on a macOS CI runner and
# writes an installable IPA. Uses only Apple's own tools (security, codesign).
#
# Environment:
#   SIGNING_CERTIFICATE_P12   base64 of your .p12          (secret)
#   SIGNING_CERTIFICATE_PASSWORD  its password             (secret)
#   PROVISIONING_PROFILE      base64 of your .mobileprovision (secret)
#   APP_BUNDLE_ID             optional bundle ID override  (repository variable)
# Usage: scripts/ci_sign_app.sh path/to/App.app output.ipa signing-info.json
set -euo pipefail

APP_SRC="$1"
OUTPUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
INFO_OUT="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

printf '%s' "$SIGNING_CERTIFICATE_P12" | base64 --decode > "$WORK/certificate.p12"
printf '%s' "$PROVISIONING_PROFILE" | base64 --decode > "$WORK/profile.mobileprovision"
security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"

PROFILE_VARS="$(python3 "$SCRIPTS/ci_profile.py" "$WORK/profile.plist" "$WORK/entitlements.plist" "$INFO_OUT" "${APP_BUNDLE_ID:-}")"
eval "$PROFILE_VARS"
echo "Signing as $BUNDLE_ID with a $PROFILE_KIND profile"

# A throwaway keychain holding only your identity.
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/certificate.p12" -k "$KEYCHAIN" -P "$SIGNING_CERTIFICATE_PASSWORD" -f pkcs12 -T /usr/bin/codesign
# Apple's intermediate certificates, so codesign can build the chain.
for generation in G3 G4 G5 G6; do
  if curl -fsSL -o "$WORK/wwdr-$generation.cer" "https://www.apple.com/certificateauthority/AppleWWDRCA$generation.cer"; then
    security import "$WORK/wwdr-$generation.cer" -k "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
done
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk 'NR==1 && $2 ~ /^[0-9A-F]+$/ {print $2}')
if [ -z "$IDENTITY" ]; then
  echo "::error::No usable signing identity in the .p12 (wrong password, or no private key?)"
  exit 1
fi

mkdir -p "$WORK/Payload"
cp -R "$APP_SRC" "$WORK/Payload/"
APP="$WORK/Payload/$(basename "$APP_SRC")"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
cp "$WORK/profile.mobileprovision" "$APP/embedded.mobileprovision"
rm -rf "$APP/_CodeSignature"

# Inside out: frameworks, dylibs and extensions first, then the app.
find "$APP" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print0 |
  while IFS= read -r -d '' item; do
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$item"
  done
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none \
  --entitlements "$WORK/entitlements.plist" --generate-entitlement-der "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

rm -f "$OUTPUT"
(cd "$WORK" && zip -qry "$OUTPUT" Payload)
echo "Wrote $OUTPUT"
