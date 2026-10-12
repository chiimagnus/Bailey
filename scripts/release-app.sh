#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export KERO_VERSION="${1:?需要 X.Y.Z 版本}" KERO_BUILD_NUMBER="${2:?需要构建号}"
bash scripts/build-app.sh release release

mkdir -p build/releases
archive="$PWD/build/releases/kero-$KERO_VERSION-macos-arm64.zip"
[ ! -e "$archive" ] || { echo "拒绝覆盖已有发布包：$archive" >&2; exit 1; }
temporary=$(mktemp -d "$PWD/build/releases/.verify.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
app="$PWD/build/DerivedData/Build/Products/Release/Kero.app"

verify_app() {
    local bundle="$1" info="$1/Contents/Info.plist" signature fingerprint
    codesign --verify --deep --strict "$bundle"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = chiimagnus.kero ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info")" = Kero ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")" = kero ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" = "$KERO_VERSION" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" = "$KERO_BUILD_NUMBER" ]
    lipo "$bundle/Contents/MacOS/kero" -verify_arch arm64
    signature=$(codesign -dv --verbose=4 "$bundle" 2>&1)
    printf '%s\n' "$signature" | grep -Fx "TeamIdentifier=$SIGNING_TEAM" >/dev/null
    printf '%s\n' "$signature" | grep '^Authority=Apple Development:' >/dev/null
    codesign -d --extract-certificates="$temporary/cert-" "$bundle"
    fingerprint=$(shasum -a 1 "$temporary/cert-0" | awk '{print toupper($1)}')
    [ "$fingerprint" = "$SIGNING_IDENTITY" ]
    openssl x509 -inform DER -in "$temporary/cert-0" -checkend 0 -noout
}

verify_app "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary/package.zip"
ditto -x -k "$temporary/package.zip" "$temporary/unpacked"
verify_app "$temporary/unpacked/Kero.app"
mv "$temporary/package.zip" "$archive"
printf '已验证发布包：%s\n' "$archive"
