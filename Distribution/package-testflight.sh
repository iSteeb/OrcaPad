#!/bin/bash
# Turns the unsigned `xtool dev build -c release` app into a signed App Store
# IPA and (optionally) uploads it to TestFlight.
#
# Runs ONLY on the GitHub-hosted macOS runner (.github/workflows/testflight.yml):
# it needs Xcode's actool, codesign, security and altool. The Linux dev box
# keeps its xtool loop unchanged. Bash 3.2 compatible (macOS /bin/bash).
#
# Environment:
#   BUILD_NUMBER             CFBundleVersion for this upload, strictly increasing
#   DIST_P12_BASE64          Apple Distribution identity (.p12, base64)
#   DIST_P12_PASSWORD        its export password
#   APPSTORE_PROFILE_BASE64  App Store provisioning profile for ie.duz.OrcaPad (base64)
#   ORCAPAD_UPLOAD           1 = validate + upload to App Store Connect, 0 = package only
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8   App Store Connect API key (upload only)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="${APP_SRC:-$ROOT/xtool/OrcaPad.app}"
WORK="${RUNNER_TEMP:-/tmp}/orcapad-package"
BUNDLE_ID="ie.duz.OrcaPad"
PLISTBUDDY=/usr/libexec/PlistBuddy

fail() { echo "::error::$*" >&2; exit 1; }
step() { echo "==> $*"; }
require_env() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || fail "missing required environment variable $v"
    done
}

require_env BUILD_NUMBER DIST_P12_BASE64 DIST_P12_PASSWORD APPSTORE_PROFILE_BASE64 ORCAPAD_UPLOAD
case "$ORCAPAD_UPLOAD" in
    0|1) ;;
    *) fail "ORCAPAD_UPLOAD must be 0 or 1 (got '$ORCAPAD_UPLOAD')" ;;
esac
[ "$ORCAPAD_UPLOAD" = 0 ] || require_env ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "BUILD_NUMBER '$BUILD_NUMBER' is not 1-3 period-separated integers"
[ -d "$APP_SRC" ] || fail "no app at $APP_SRC (run: xtool dev build -c release)"

KEYCHAIN="$WORK/signing.keychain-db"
ASC_KEY_DIR="$HOME/.appstoreconnect/private_keys"
cleanup() {
    if [ -f "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" || echo "::warning::could not delete $KEYCHAIN"
    fi
    rm -f "$WORK/dist.p12" "$ASC_KEY_DIR/AuthKey_${ASC_KEY_ID:-none}.p8"
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK/Payload"
APP="$WORK/Payload/OrcaPad.app"
ditto "$APP_SRC" "$APP"
PLIST="$APP/Info.plist"

# --- toolchain facts (stamped into Info.plist; must describe THIS build) ---
XCODE_VERSION="$(xcodebuild -version | awk 'NR==1 {print $2}')"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
XCODE_DTXCODE="$($PLISTBUDDY -c 'Print :DTXcode' "$(xcode-select -p)/../Info.plist")"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-platform-version)"
SDK_BUILD="$(xcrun --sdk iphoneos --show-sdk-build-version)"
MACOS_BUILD="$(sw_vers -buildVersion)"
step "Xcode $XCODE_VERSION ($XCODE_BUILD, DTXcode $XCODE_DTXCODE), iphoneos $SDK_VERSION ($SDK_BUILD), macOS $MACOS_BUILD"
for value in "$XCODE_VERSION" "$XCODE_BUILD" "$XCODE_DTXCODE" "$SDK_VERSION" "$SDK_BUILD" "$MACOS_BUILD"; do
    [ -n "$value" ] || fail "could not determine the Xcode/SDK versions"
done

actual_id="$($PLISTBUDDY -c 'Print :CFBundleIdentifier' "$PLIST")"
[ "$actual_id" = "$BUNDLE_ID" ] || fail "built app is $actual_id, expected $BUNDLE_ID (xtool.yml bundleID)"
MIN_OS="$($PLISTBUDDY -c 'Print :MinimumOSVersion' "$PLIST")"

# --- 1. app icon: compile Distribution/AppIcon.xcassets (xtool can't) ---
step "compiling the app icon asset catalog"
xcrun actool "$ROOT/Distribution/AppIcon.xcassets" \
    --compile "$APP" \
    --platform iphoneos \
    --minimum-deployment-target "$MIN_OS" \
    --app-icon AppIcon \
    --target-device iphone --target-device ipad \
    --output-partial-info-plist "$WORK/icon-partial.plist" \
    --output-format human-readable-text --errors --warnings --notices
[ -f "$APP/Assets.car" ] || fail "actool produced no Assets.car"
$PLISTBUDDY -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$WORK/icon-partial.plist" >/dev/null ||
    fail "actool's partial Info.plist has no primary icon"
$PLISTBUDDY -c "Merge $WORK/icon-partial.plist" "$PLIST"

# --- 2. privacy manifest at the app root ---
step "adding the privacy manifest"
cp "$ROOT/Distribution/PrivacyInfo.xcprivacy" "$APP/PrivacyInfo.xcprivacy"
plutil -lint "$APP/PrivacyInfo.xcprivacy"

# Required-reason APIs the executable references must be declared (App Store
# Connect rejects the upload otherwise, ITMS-91053). Catch it here, loudly.
step "checking required-reason API declarations"
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

# --- 3. Info.plist: build number + truthful toolchain keys ---
# xtool writes no DT* keys into the app plist, and resource bundles built on
# Linux carry placeholders (DTXcodeBuild 99T999). App Store Connect reads
# these to validate the toolchain, so stamp what THIS Xcode actually built.
step "stamping Info.plist files (build $BUILD_NUMBER)"
find "$APP" -name Info.plist -print0 | while IFS= read -r -d '' plist; do
    /usr/bin/python3 - "$plist" "$PLIST" "$BUILD_NUMBER" "$XCODE_DTXCODE" "$XCODE_BUILD" \
        "$SDK_VERSION" "$SDK_BUILD" "$MACOS_BUILD" <<'PY'
import plistlib, sys
path, main_plist, build, dtxcode, xcode_build, sdk_version, sdk_build, macos_build = sys.argv[1:]
with open(path, "rb") as f:
    info = plistlib.load(f)
info.update({
    "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
    "DTPlatformBuild": sdk_build,
    "DTPlatformName": "iphoneos",
    "DTPlatformVersion": sdk_version,
    "DTSDKBuild": sdk_build,
    "DTSDKName": "iphoneos" + sdk_version,
    "DTXcode": dtxcode,
    "DTXcodeBuild": xcode_build,
})
if path == main_plist:
    info["CFBundleVersion"] = build
    info["BuildMachineOSBuild"] = macos_build
with open(path, "wb") as f:
    plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
PY
done
if grep -rl '99T999' "$APP" --include=Info.plist; then
    fail "placeholder toolchain values remain in the bundle"
fi

# --- 4. signing material ---
step "preparing the signing keychain"
printf '%s' "$APPSTORE_PROFILE_BASE64" | base64 --decode > "$WORK/profile.mobileprovision"
security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"
TEAM_ID="$($PLISTBUDDY -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")"
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
print(f"profile '{info['Name']}' expires {expires:%Y-%m-%d} ({left.days} days)")
if left.days < 1:
    sys.exit("::error::the App Store provisioning profile has expired; regenerate it")
if left.days < 30:
    print(f"::warning::the App Store provisioning profile expires in {left.days} days")
PY

KEYCHAIN_PASSWORD="$(uuidgen)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
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
# The profile must embed exactly this certificate.
/usr/bin/python3 - "$WORK/profile.plist" "$IDENTITY" <<'PY'
import hashlib, plistlib, sys
info = plistlib.load(open(sys.argv[1], "rb"))
wanted = sys.argv[2].upper()
found = [hashlib.sha1(cert).hexdigest().upper() for cert in info["DeveloperCertificates"]]
if wanted not in found:
    sys.exit(f"::error::the profile does not contain the .p12 certificate {wanted} (profile has {found})")
PY

# --- 5. sign (nested resource bundle first, then the app) ---
step "signing for App Store distribution (team $TEAM_ID)"
cp "$WORK/profile.mobileprovision" "$APP/embedded.mobileprovision"
cat > "$WORK/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM_ID.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
	<key>get-task-allow</key>
	<false/>
	<key>beta-reports-active</key>
	<true/>
</dict>
</plist>
EOF
plutil -lint "$WORK/entitlements.plist"
find "$APP" -mindepth 1 -maxdepth 1 -name '*.bundle' -print0 | while IFS= read -r -d '' bundle; do
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$bundle"
done
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none \
    --entitlements "$WORK/entitlements.plist" --generate-entitlement-der "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" | plutil -p -

# --- 6. IPA ---
step "packaging the IPA"
IPA="$WORK/OrcaPad.ipa"
(cd "$WORK" && ditto -c -k --norsrc --keepParent Payload "$IPA")
# grep -c exits 1 on zero matches; the count itself is the checked result
ipa_members="$(unzip -l "$IPA" | grep -cE 'Payload/OrcaPad.app/(Info.plist|embedded.mobileprovision|Assets.car|PrivacyInfo.xcprivacy|_CodeSignature/CodeResources)$' || true)"
[ "$ipa_members" = 5 ] || fail "IPA is missing required members (found $ipa_members of 5)"
ls -l "$IPA"
echo "ipa=$IPA" >> "${GITHUB_OUTPUT:-/dev/null}"

[ "$ORCAPAD_UPLOAD" = 1 ] || { step "ORCAPAD_UPLOAD=0: not uploading"; exit 0; }

# --- 7. upload to App Store Connect (TestFlight) ---
mkdir -p "$ASC_KEY_DIR"
( umask 077; printf '%s\n' "$ASC_KEY_P8" > "$ASC_KEY_DIR/AuthKey_$ASC_KEY_ID.p8" )
step "validating with App Store Connect"
xcrun altool --validate-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
step "uploading build $BUILD_NUMBER"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
step "uploaded: App Store Connect processes the build, then TestFlight offers it to internal testers"
