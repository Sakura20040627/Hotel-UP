#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d)"
keychain="$scratch/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

: "${HOTELFLOW_TEAM:?}" "${HOTELFLOW_CERTIFICATE:?}" "${HOTELFLOW_CERTIFICATE_PASSWORD:?}"
: "${HOTELFLOW_APP_PROFILE:?}" "${HOTELFLOW_SHARE_PROFILE:?}"
password="$(openssl rand -hex 24)"
security create-keychain -p "$password" "$keychain"
security unlock-keychain -p "$password" "$keychain"
printf '%s' "$HOTELFLOW_CERTIFICATE" | base64 -D > "$scratch/cert.p12"
security import "$scratch/cert.p12" -k "$keychain" -P "$HOTELFLOW_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
identity="$(security find-identity -v -p codesigning "$keychain" | awk '/[0-9]+\)/ && !found++ { print $2 }')"
test -n "$identity"

ditto build/package/Payload "$scratch/Payload"
app="$scratch/Payload/HotelFlow.app"
share="$app/PlugIns/HotelFlowShare.appex"
printf '%s' "$HOTELFLOW_APP_PROFILE" | base64 -D > "$app/embedded.mobileprovision"
printf '%s' "$HOTELFLOW_SHARE_PROFILE" | base64 -D > "$share/embedded.mobileprovision"

sign() {
  local bundle="$1" identifier="$2" profile="$scratch/profile.plist" entitlements="$scratch/entitlements.plist"
  security cms -D -i "$bundle/embedded.mobileprovision" > "$profile"
  python3 - "$profile" "$entitlements" "$identifier" <<'PY'
import datetime, os, plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    profile = plistlib.load(stream)
team = os.environ['HOTELFLOW_TEAM']
group = os.environ['HOTELFLOW_APP_GROUP']
ent = profile['Entitlements']
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile'
assert team in profile['TeamIdentifier'], 'Team ID mismatch'
assert ent['application-identifier'] == f'{team}.{sys.argv[3]}', 'An explicit profile matching the bundle ID is required'
assert group in ent.get('com.apple.security.application-groups', []), 'App Group missing in profile'
ent['com.apple.security.application-groups'] = [group]
with open(sys.argv[2], 'wb') as stream:
    plistlib.dump(ent, stream)
PY
  codesign --force --keychain "$keychain" --sign "$identity" --entitlements "$entitlements" "$bundle"
}

sign "$share" "$HOTELFLOW_BUNDLE_ID.share"
sign "$app" "$HOTELFLOW_BUNDLE_ID"
codesign --verify --deep --strict "$app"
output="$PWD/build/HotelFlow-signed.ipa"
(cd "$scratch" && ditto -c -k --keepParent Payload "$output")
unzip -t "$output"
