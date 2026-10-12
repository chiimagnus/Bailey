#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    debug) configuration=Debug ;;
    release) configuration=Release ;;
    *) echo '用法：bash scripts/build-app.sh debug|release [local|adhoc|release]' >&2; exit 2 ;;
esac

signing=()
case "${2:-local}" in
    local) ;;
    adhoc) signing=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual) ;;
    release)
        : "${SIGNING_IDENTITY:?需要 Apple Development 证书的 SHA-1}"
        : "${SIGNING_TEAM:?需要证书所属 Team ID}"
        [[ "$SIGNING_IDENTITY" =~ ^[A-F0-9]{40}$ ]] || exit 2
        [[ "$SIGNING_TEAM" =~ ^[A-Z0-9]{10}$ ]] || exit 2
        keychain=()
        if [ -n "${SIGNING_KEYCHAIN:-}" ]; then keychain=("$SIGNING_KEYCHAIN"); fi
        identities=$(security find-identity -v -p codesigning ${keychain[@]+"${keychain[@]}"})
        printf '%s\n' "$identities" | grep -F "$SIGNING_IDENTITY \"Apple Development:" >/dev/null || {
            echo '未找到有效 Apple Development 签名身份；禁止降级发包。' >&2; exit 1;
        }
        signing=("CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" "DEVELOPMENT_TEAM=$SIGNING_TEAM" CODE_SIGN_STYLE=Manual)
        if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
            signing+=("OTHER_CODE_SIGN_FLAGS=--keychain \"$SIGNING_KEYCHAIN\"")
        fi
        ;;
    *) echo '未知签名模式' >&2; exit 2 ;;
esac

version=()
if [ -n "${KERO_VERSION:-}" ] || [ -n "${KERO_BUILD_NUMBER:-}" ]; then
    [[ "${KERO_VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 2
    [[ "${KERO_BUILD_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || exit 2
    version=("MARKETING_VERSION=$KERO_VERSION" "CURRENT_PROJECT_VERSION=$KERO_BUILD_NUMBER")
fi

xcodebuild -project kero.xcodeproj -scheme kero -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
    -skipPackageUpdates -disableAutomaticPackageResolution \
    ${signing[@]+"${signing[@]}"} ${version[@]+"${version[@]}"} build
codesign --verify --deep --strict "build/DerivedData/Build/Products/$configuration/Kero.app"
