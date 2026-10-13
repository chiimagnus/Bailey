# Kero: Xcode 负责构建与测试，Make 只提供统一入口。
.DEFAULT_GOAL := help
.NOTPARALLEL:

PROJECT := kero.xcodeproj
SCHEME := kero
CONFIGURATION ?= Debug
DESTINATION := platform=macOS,arch=arm64
DERIVED_DATA := build/DerivedData
SOURCE_PACKAGES := build/SourcePackages
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Kero.app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/Kero.app
ARCHIVE := build/releases/kero-$(VERSION)-macos-arm64.zip

# 按 Package.resolved 固定版本；与 Xcode 的工程、scheme、测试目标共用。
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIGURATION) -destination '$(DESTINATION)' \
	-derivedDataPath $(DERIVED_DATA) -clonedSourcePackagesDirPath $(SOURCE_PACKAGES) \
	-skipPackageUpdates -disableAutomaticPackageResolution
TEST_SELECTION = $(if $(strip $(ONLY_TESTING)),-only-testing:$(ONLY_TESTING))
VERSION_FLAGS = $(if $(strip $(VERSION)),MARKETING_VERSION=$(VERSION)) \
	$(if $(strip $(BUILD_NUMBER)),CURRENT_PROJECT_VERSION=$(BUILD_NUMBER))

ifeq ($(SIGNING),adhoc)
SIGNING_FLAGS = CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
else ifeq ($(SIGNING),release)
SIGNING_FLAGS = 'CODE_SIGN_IDENTITY=$(SIGNING_IDENTITY)' 'DEVELOPMENT_TEAM=$(SIGNING_TEAM)' \
	CODE_SIGN_STYLE=Manual $(if $(strip $(SIGNING_KEYCHAIN)),'OTHER_CODE_SIGN_FLAGS=--keychain "$(SIGNING_KEYCHAIN)"')
else
SIGNING_FLAGS =
endif

.PHONY: help doctor build build\:release test package clean

help:
	@printf '%s\n' \
		'Kero · Xcode 原生构建与测试' \
		'  make build                              Debug 构建并验签' \
		'  make test                               运行 Xcode XCTest' \
		'  make test SIGNING=adhoc                 临时签名运行 XCTest（CI）' \
		'  make build:release                      Release 构建并验签' \
		'  make build:release SIGNING=adhoc        无开发证书的 CI 构建' \
		'  make test ONLY_TESTING=KeroTests/类名     只运行指定 XCTest' \
		'  make package VERSION=X.Y.Z BUILD_NUMBER=N  验证正式签名并制作 ZIP' \
		'  make clean                              Xcode 清理构建产物' \
		'  make doctor                             检查 Xcode 工具链'

doctor:
	@command -v xcodebuild >/dev/null
	@test -d '$(PROJECT)'
	@xcodebuild -version

build:
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) build
	codesign --verify --deep --strict '$(APP)'

build\:release: CONFIGURATION = Release
build\:release: build

test:
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(TEST_SELECTION) test
ifeq ($(SIGNING),adhoc)
	@set -eu; for bundle in '$(APP)' '$(APP)/Contents/PlugIns/KeroTests.xctest'; do \
		codesign --verify --deep --strict "$$bundle"; \
		codesign -dvvv "$$bundle" 2>&1 | grep -Fx 'Signature=adhoc' >/dev/null; \
	done
endif

package:
	@python3 -c 'import re,sys; v,n,identity,team=sys.argv[1:]; assert re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)",v), "版本必须为 X.Y.Z"; assert re.fullmatch(r"[1-9][0-9]*",n), "构建号无效"; assert re.fullmatch(r"[A-F0-9]{40}",identity), "签名 SHA-1 无效"; assert re.fullmatch(r"[A-Z0-9]{10}",team), "Team ID 无效"' '$(VERSION)' '$(BUILD_NUMBER)' '$(SIGNING_IDENTITY)' '$(SIGNING_TEAM)'
	@security find-identity -v -p codesigning $(if $(strip $(SIGNING_KEYCHAIN)),'$(SIGNING_KEYCHAIN)') | grep -F '$(SIGNING_IDENTITY) "Apple Development:' >/dev/null || { echo '没有有效的 Apple Development 签名身份' >&2; exit 1; }
	@test ! -e '$(ARCHIVE)' || { echo '发布包已存在，拒绝覆盖：$(ARCHIVE)' >&2; exit 1; }
	@$(MAKE) --no-print-directory 'build:release' SIGNING=release VERSION='$(VERSION)' BUILD_NUMBER='$(BUILD_NUMBER)'
	@mkdir -p build/releases
	@set -eu; temp=$$(mktemp -d build/releases/.verify.XXXXXX); trap 'rm -rf "$$temp"' EXIT; \
		app='$(RELEASE_APP)'; \
		ditto -c -k --sequesterRsrc --keepParent "$$app" "$$temp/package.zip"; \
		ditto -x -k "$$temp/package.zip" "$$temp/unpacked"; \
		for bundle in "$$app" "$$temp/unpacked/Kero.app"; do \
			info="$$bundle/Contents/Info.plist"; \
			codesign --verify --deep --strict "$$bundle"; \
			codesign -d --extract-certificates="$$temp/cert-" "$$bundle"; \
			fingerprint=$$(shasum -a 1 "$$temp/cert-0" | awk '{print toupper($$1)}'); \
			test "$$fingerprint" = '$(SIGNING_IDENTITY)'; \
			openssl x509 -inform DER -in "$$temp/cert-0" -checkend 0 -noout; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$info")" = chiimagnus.kero; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$$info")" = Kero; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$$info")" = kero; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$info")" = '$(VERSION)'; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$info")" = '$(BUILD_NUMBER)'; \
			lipo "$$bundle/Contents/MacOS/kero" -verify_arch arm64; \
			signature=$$(codesign -dv --verbose=4 "$$bundle" 2>&1); \
			printf '%s\n' "$$signature" | grep -Fx 'TeamIdentifier=$(SIGNING_TEAM)' >/dev/null; \
			printf '%s\n' "$$signature" | grep '^Authority=Apple Development:' >/dev/null; \
		done; \
		mv "$$temp/package.zip" '$(ARCHIVE)'; \
		printf '已验证发布包：%s\n' '$(ARCHIVE)'

clean:
	$(XCODEBUILD) clean
