#!/bin/sh
# Builds, signs and zips a release of Paddock.
#
#   $ scripts/build-release.sh 0.2.0
#   build/Paddock-0.2.0.zip
#
# The version is stamped into the bundle from the command line; project.yml
# only carries the 0.0.0 development placeholder. Signing is ad-hoc unless
# CODE_SIGN_IDENTITY names a certificate (the Developer ID path, see
# docs/releasing.md). Every property a release depends on is asserted at the
# end, so a wrong build fails here rather than on somebody's Mac.
set -eu

version="${1:?usage: $0 X.Y.Z}"
case "$version" in
    *[!0-9.]* | .* | *. | *..*)
        echo "version '$version' is not of the form X.Y.Z" >&2
        exit 2
        ;;
esac
identity="${CODE_SIGN_IDENTITY:--}"

cd "$(dirname "$0")/.."
rm -rf build
mkdir -p build

xcodegen generate
xcodebuild -project Paddock.xcodeproj -scheme Paddock -configuration Release \
    -derivedDataPath DerivedData -archivePath build/Paddock.xcarchive \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" \
    CODE_SIGN_IDENTITY="$identity" \
    archive -quiet

app=build/Paddock.app
cp -R build/Paddock.xcarchive/Products/Applications/Paddock.app "$app"

fail() {
    echo "release check failed: $*" >&2
    exit 1
}
plist="$app/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print $1" "$plist" 2>/dev/null || true; }

[ "$(read_plist CFBundleShortVersionString)" = "$version" ] || fail "CFBundleShortVersionString is not $version"
[ "$(read_plist CFBundleVersion)" = "$version" ] || fail "CFBundleVersion is not $version"
[ -n "$(read_plist SUPublicEDKey)" ] || fail "SUPublicEDKey is empty"
[ -n "$(read_plist SUFeedURL)" ] || fail "SUFeedURL is empty"
[ -d "$app/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle.framework is not embedded"

archs="$(lipo -archs "$app/Contents/MacOS/Paddock")"
case "$archs" in
    *arm64*x86_64* | *x86_64*arm64*) ;;
    *) fail "binary is not universal: $archs" ;;
esac

codesign --verify --deep --strict "$app" || fail "code signature does not verify"
codesign -d --entitlements - "$app" 2>/dev/null | grep -q 'disable-library-validation' \
    || fail "disable-library-validation entitlement is missing (Sparkle would not load)"
if [ "$identity" = "-" ]; then
    codesign -dvv "$app" 2>&1 | grep -q 'Signature=adhoc' || fail "expected an ad-hoc signature"
fi

zip="build/Paddock-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
echo "$zip"
