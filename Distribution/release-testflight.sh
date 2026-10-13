#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
# Release build for TestFlight, with Xcode only (no xtool in CI):
#   App Store profile + Apple Distribution identity -> temporary keychain
#   XcodeGen project (Distribution/project.yml) -> xcodebuild archive
#   checks on the archived app -> exportArchive (App Store Connect) -> altool upload
# Distribution to the external TestFlight group is the next workflow step
# (Distribution/asc_testflight.py).
#
# Runs ONLY on the GitHub-hosted macOS runner (.github/workflows/testflight.yml,
# on `release*` tags). Bash 3.2 compatible (macOS /bin/bash).
#
# Environment:
#   BUILD_NUMBER             CFBundleVersion, strictly increasing per upload
#   MARKETING_VERSION        optional CFBundleShortVersionString override
#   ORCAPAD_SOURCE_REF        optional exact-source identity (COMPLIANCE.md
#                            W2: "<release-tag>+<commit-sha>") baked into
#                            App-Info.plist and shown by the About screen
#   XCODEGEN                 path to the pinned xcodegen binary
#   DIST_P12_BASE64          Apple Distribution identity (.p12, base64)
#   DIST_P12_PASSWORD        its export password
#   APPSTORE_PROFILE_BASE64  App Store provisioning profile for ie.duz.OrcaPad (base64)
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8   App Store Connect API key (upload)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/orcapad-release"
BUNDLE_ID="ie.duz.OrcaPad"
PLISTBUDDY=/usr/libexec/PlistBuddy
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

fail() { echo "::error::$*" >&2; exit 1; }
step() { echo "==> $*"; }
require_env() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || fail "missing required environment variable $v"
    done
}

require_env BUILD_NUMBER XCODEGEN DIST_P12_BASE64 DIST_P12_PASSWORD APPSTORE_PROFILE_BASE64 \
    ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "BUILD_NUMBER '$BUILD_NUMBER' is not 1-3 period-separated integers"
if [ -n "${MARKETING_VERSION:-}" ]; then
    [[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
        fail "MARKETING_VERSION '$MARKETING_VERSION' is not X.Y or X.Y.Z"
fi
[ -x "$XCODEGEN" ] || fail "xcodegen not found at $XCODEGEN"

# ASC_KEY_ID & co. come from the environment (checked by require_env above)
# shellcheck disable=SC2153
ASC_KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
KEYCHAIN="$WORK/signing.keychain-db"
INSTALLED_PROFILE=""
cleanup() {
    if [ -f "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" || echo "::warning::could not delete $KEYCHAIN"
    fi
    rm -f "$WORK/dist.p12" "$ASC_KEY_FILE"
    [ -z "$INSTALLED_PROFILE" ] || rm -f "$INSTALLED_PROFILE"
}
trap cleanup EXIT
rm -rf "$WORK"
mkdir -p "$WORK"

# --- 1. provisioning profile: must be the App Store profile for this app ---
step "checking the App Store provisioning profile"
printf '%s' "$APPSTORE_PROFILE_BASE64" | base64 --decode > "$WORK/profile.mobileprovision"
security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"
TEAM_ID="$($PLISTBUDDY -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")"
PROFILE_UUID="$($PLISTBUDDY -c 'Print :UUID' "$WORK/profile.plist")"
PROFILE_APP_ID="$($PLISTBUDDY -c 'Print :Entitlements:application-identifier' "$WORK/profile.plist")"
[ "$PROFILE_APP_ID" = "$TEAM_ID.$BUNDLE_ID" ] ||
    fail "profile is for $PROFILE_APP_ID, expected $TEAM_ID.$BUNDLE_ID"
if $PLISTBUDDY -c 'Print :ProvisionedDevices' "$WORK/profile.plist" >/dev/null 2>&1; then
    fail "profile lists devices: it is a development/ad hoc profile, not App Store"
fi
[ "$($PLISTBUDDY -c 'Print :Entitlements:beta-reports-active' "$WORK/profile.plist")" = true ] ||
    fail "profile lacks beta-reports-active: not an App Store distribution profile"
/usr/bin/python3 - "$WORK/profile.plist" <<'PY'
import datetime, plistlib, sys
info = plistlib.load(open(sys.argv[1], "rb"))
expires = info["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
left = expires - datetime.datetime.now(datetime.timezone.utc)
print(f"profile '{info['Name']}' {info['UUID']} expires {expires:%Y-%m-%d} ({left.days} days)")
if left.days < 1:
    sys.exit("::error::the App Store provisioning profile has expired; regenerate it")
if left.days < 30:
    print(f"::warning::the App Store provisioning profile expires in {left.days} days")
PY
mkdir -p "$PROFILES_DIR"
INSTALLED_PROFILE="$PROFILES_DIR/$PROFILE_UUID.mobileprovision"
cp "$WORK/profile.mobileprovision" "$INSTALLED_PROFILE"

# --- 2. signing identity in a temporary keychain ---
step "preparing the signing keychain"
KEYCHAIN_PASSWORD="$(uuidgen)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 7200 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# Apple WWDR intermediates so the identity's chain validates on any image.
for generation in G3 G6; do
    curl -fsSL -o "$WORK/AppleWWDRCA$generation.cer" \
        "https://www.apple.com/certificateauthority/AppleWWDRCA$generation.cer"
    security import "$WORK/AppleWWDRCA$generation.cer" -k "$KEYCHAIN"
done
printf '%s' "$DIST_P12_BASE64" | base64 --decode > "$WORK/dist.p12"
security import "$WORK/dist.p12" -k "$KEYCHAIN" -P "$DIST_P12_PASSWORD" -f pkcs12 \
    -T /usr/bin/codesign -T /usr/bin/security
rm -f "$WORK/dist.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN")"
echo "$IDENTITIES"
IDENTITY="$(awk '/"Apple Distribution: / {print $2}' <<<"$IDENTITIES")"
[ -n "$IDENTITY" ] || fail "no valid Apple Distribution identity in the imported .p12"
[ "$(wc -l <<<"$IDENTITY" | tr -d ' ')" = 1 ] || fail "more than one Apple Distribution identity"
/usr/bin/python3 - "$WORK/profile.plist" "$IDENTITY" <<'PY'
import hashlib, plistlib, sys
info = plistlib.load(open(sys.argv[1], "rb"))
wanted = sys.argv[2].upper()
found = [hashlib.sha1(cert).hexdigest().upper() for cert in info["DeveloperCertificates"]]
if wanted not in found:
    sys.exit(f"::error::the profile does not contain the .p12 certificate {wanted} (profile has {found})")
PY

# --- 3. Xcode project + archive ---
step "baking the exact-source identity into App-Info.plist"
SRC_REF="${ORCAPAD_SOURCE_REF:-}"
if [ -n "$SRC_REF" ]; then
    # printable single line only — it lands in a plist and on the About screen
    if ! printf '%s' "$SRC_REF" | grep -Eq '^[A-Za-z0-9._+/: -]+$'; then
        fail "ORCAPAD_SOURCE_REF has unexpected characters: $SRC_REF"
    fi
    $PLISTBUDDY -c "Set :ORCAPAD_SOURCE_REF $SRC_REF" "$ROOT/App-Info.plist"
fi
step "generating the Xcode project (XcodeGen $("$XCODEGEN" --version))"
ORCAPAD_TEAM_ID="$TEAM_ID" ORCAPAD_PROFILE_UUID="$PROFILE_UUID" \
    "$XCODEGEN" generate --spec "$ROOT/Distribution/project.yml" --project "$ROOT/Distribution"
ARCHIVE="$WORK/OrcaPad.xcarchive"
VERSION_OVERRIDE=()
[ -z "${MARKETING_VERSION:-}" ] || VERSION_OVERRIDE=("MARKETING_VERSION=$MARKETING_VERSION")
step "archiving build $BUILD_NUMBER ${MARKETING_VERSION:+(version $MARKETING_VERSION)}"
xcodebuild -project "$ROOT/Distribution/OrcaPad.xcodeproj" -scheme OrcaPadApp \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${VERSION_OVERRIDE[@]+"${VERSION_OVERRIDE[@]}"} \
    OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
    archive

# --- 4. checks on the archived app (fail here, not in Apple's mail) ---
APP="$ARCHIVE/Products/Applications/OrcaPad.app"
PLIST="$APP/Info.plist"
[ -d "$APP" ] || fail "archive has no Products/Applications/OrcaPad.app"
step "checking the archived app"
[ "$($PLISTBUDDY -c 'Print :CFBundleIdentifier' "$PLIST")" = "$BUNDLE_ID" ] || fail "wrong bundle id"
[ "$($PLISTBUDDY -c 'Print :CFBundleVersion' "$PLIST")" = "$BUILD_NUMBER" ] || fail "wrong build number"
[ "$($PLISTBUDDY -c 'Print :ITSAppUsesNonExemptEncryption' "$PLIST")" = false ] ||
    fail "ITSAppUsesNonExemptEncryption missing from the app Info.plist"
$PLISTBUDDY -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$PLIST" >/dev/null ||
    fail "no primary app icon in Info.plist (asset catalog not compiled?)"
$PLISTBUDDY -c 'Print :DTXcodeBuild' "$PLIST" >/dev/null || fail "no DTXcodeBuild in Info.plist"
[ -f "$APP/Assets.car" ] || fail "no Assets.car in the app"
[ -f "$APP/PrivacyInfo.xcprivacy" ] || fail "no PrivacyInfo.xcprivacy at the app root"
SRCREF_PLIST="$($PLISTBUDDY -c 'Print :ORCAPAD_SOURCE_REF' "$PLIST" 2>/dev/null || true)"
[ -n "$SRCREF_PLIST" ] || fail "no ORCAPAD_SOURCE_REF in the app Info.plist (AGPL source traceability, COMPLIANCE.md W2)"
if [ -n "$SRC_REF" ] && [ "$SRCREF_PLIST" != "$SRC_REF" ]; then
    fail "archived ORCAPAD_SOURCE_REF '$SRCREF_PLIST' != requested '$SRC_REF'"
fi
echo "source ref: $SRCREF_PLIST"
VERSION="$($PLISTBUDDY -c 'Print :CFBundleShortVersionString' "$PLIST")"
codesign --verify --deep --strict --verbose=2 "$APP"

# Required-reason APIs the executable references must be declared (App Store
# Connect rejects the upload otherwise, ITMS-91053).
EXE="$APP/$($PLISTBUDDY -c 'Print :CFBundleExecutable' "$PLIST")"
SYMBOLS="$(xcrun nm -u -j "$EXE")"
STRINGS="$(strings -a "$EXE")"
DECLARED="$(/usr/bin/python3 -c '
import plistlib, sys
for entry in plistlib.load(open(sys.argv[1], "rb")).get("NSPrivacyAccessedAPITypes", []):
    print(entry["NSPrivacyAccessedAPIType"])
' "$APP/PrivacyInfo.xcprivacy")"
uses() { grep -Eq "$1" <<<"$SYMBOLS"; }
REFERENCED=""
uses '^_(stat|fstat|fstatat|lstat|getattrlist|fgetattrlist|getattrlistat|getattrlistbulk)$|^_NSFile(Creation|Modification)Date$|^_NSURL(Creation|ContentModification)DateKey$' &&
    REFERENCED="$REFERENCED NSPrivacyAccessedAPICategoryFileTimestamp"
uses '^_(statfs|fstatfs|statvfs|fstatvfs)$|^_NSFileSystem(Free)?Size$|^_NSURLVolume(Total|Available)Capacity' &&
    REFERENCED="$REFERENCED NSPrivacyAccessedAPICategoryDiskSpace"
{ uses '^_mach_absolute_time$' || grep -qx 'systemUptime' <<<"$STRINGS"; } &&
    REFERENCED="$REFERENCED NSPrivacyAccessedAPICategorySystemBootTime"
# shellcheck disable=SC2016 # literal $ in the Objective-C class symbol
uses '^_OBJC_CLASS_\$_NSUserDefaults$' &&
    REFERENCED="$REFERENCED NSPrivacyAccessedAPICategoryUserDefaults"
grep -qx 'activeInputModes' <<<"$STRINGS" &&
    REFERENCED="$REFERENCED NSPrivacyAccessedAPICategoryActiveKeyboards"
for category in $REFERENCED; do
    grep -qx "$category" <<<"$DECLARED" ||
        fail "executable uses $category but Distribution/PrivacyInfo.xcprivacy does not declare it"
done
for category in $DECLARED; do
    case " $REFERENCED " in
        *" $category "*) ;;
        *) echo "note: $category is declared but the release executable no longer references it" ;;
    esac
done
echo "required-reason categories referenced:${REFERENCED:- none}"

# --- 5. export for App Store Connect ---
step "exporting the IPA"
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key>
		<string>$PROFILE_UUID</string>
	</dict>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>testFlightInternalTestingOnly</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF
plutil -lint "$WORK/ExportOptions.plist"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
    -exportOptionsPlist "$WORK/ExportOptions.plist"
IPA="$WORK/export/OrcaPad.ipa"
[ -f "$IPA" ] || fail "export produced no OrcaPad.ipa"
ls -l "$IPA"

# --- 6. upload to App Store Connect ---
mkdir -p "$(dirname "$ASC_KEY_FILE")"
( umask 077; printf '%s\n' "$ASC_KEY_P8" > "$ASC_KEY_FILE" )
step "validating with App Store Connect"
xcrun altool --validate-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
step "uploading $VERSION ($BUILD_NUMBER)"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
{
    echo "version=$VERSION"
    echo "build=$BUILD_NUMBER"
} >> "${GITHUB_OUTPUT:-/dev/null}"
step "uploaded $VERSION ($BUILD_NUMBER)"
