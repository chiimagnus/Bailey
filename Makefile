# Bailey: Xcode 负责构建与测试，Make 只提供统一入口。
.DEFAULT_GOAL := help
.NOTPARALLEL:

PROJECT := Bailey.xcodeproj
SCHEME := Bailey
CONFIGURATION ?= Debug
DESTINATION := platform=macOS,arch=arm64
DERIVED_DATA := build/DerivedData
DEV_DERIVED_DATA := build/DerivedData-Dev
DEV_FLAGS := BAILEY_BUNDLE_SUFFIX=.dev 'BAILEY_APP_NAME=Bailey Dev' \
	BAILEY_DOCUMENT_HANDLER_RANK=None 'BAILEY_FINDER_SERVICE_NAME=Add Folder to Bailey Dev'
SOURCE_PACKAGES := build/SourcePackages
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Bailey.app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/Bailey.app
ARCHIVE := build/releases/bailey-$(VERSION)-macos-arm64.zip

# 按 Package.resolved 固定版本；与 Xcode 的工程、scheme、测试目标共用。
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIGURATION) -destination '$(DESTINATION)' \
	-derivedDataPath $(DERIVED_DATA) -clonedSourcePackagesDirPath $(SOURCE_PACKAGES) \
	-skipPackageUpdates -disableAutomaticPackageResolution
TEST_SELECTION = $(foreach TEST,$(ONLY_TESTING),-only-testing:$(TEST))
SELECTED_TESTS_PREFLIGHT = if [ -n '$(strip $(ONLY_TESTING))' ]; then \
	enumeration="$$lock/selected-tests.json"; \
	trap 'rm -f "$$enumeration"; rmdir "$$lock"' EXIT; \
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(DEV_FLAGS) $(TEST_SELECTION) \
		-enumerate-tests -test-enumeration-format json -test-enumeration-output-path "$$enumeration" test > /dev/null; \
	python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); full=[g["name"]+"/"+c["name"]+"/"+t["name"].removesuffix("()") for p in j["values"] for g in p["children"] for c in g["children"] for t in c["children"] if t["kind"]=="test" and not t.get("disabled",False)]; missing=[s for s in sys.argv[2].split() if not any(p==s or p.startswith(s+"/") for p in full)]; print("Selected XCTest methods:",len(full)); sys.exit("Unmatched XCTest selector: "+", ".join(missing) if missing else 0)' "$$enumeration" '$(strip $(ONLY_TESTING))'; \
	rm -f "$$enumeration"; \
fi
DEV_OPERATION_LOCK = set -eu; mkdir -p '$(CURDIR)/build'; \
	lock='$(CURDIR)/build/.bailey-dev-test.lock'; \
	mkdir "$$lock" 2>/dev/null || { \
		echo '无法取得 Bailey Dev 构建／测试锁；请等待已有操作结束。若上次操作被强制终止，先确认没有相关进程再移除 build/.bailey-dev-test.lock。' >&2; exit 2; \
	}; trap 'rmdir "$$lock"' EXIT
comma := ,
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

.PHONY: help doctor build build\:dev build\:release build\:ui test test\:ui package clean

help:
	@printf '%s\n' \
		'Bailey · Xcode 原生构建与测试' \
		'  make build                              正式 Bailey Debug 构建并验签' \
		'  make build:dev                          独立 Bailey Dev 构建并验签' \
		'  make test                               使用 Bailey Dev 运行完整宿主 XCTest' \
		'  make test:类名1,类名2,...              运行一个或多个宿主 XCTest 类' \
		'  make build:ui                           只编译独立 UI Test（不启动 App）' \
		'  make test:ui                            使用 Bailey Dev 执行完整 App UI Test' \
		'  make test SIGNING=adhoc                 临时签名运行 XCTest（CI）' \
		'  make build:release                      Release 构建并验签' \
		'  make build:release SIGNING=adhoc        无开发证书时验证 Release 构建' \
		'  make test ONLY_TESTING="BaileyTests/类名1 BaileyTests/类名2"  运行多个 XCTest 类' \
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

build\:dev: DERIVED_DATA = $(DEV_DERIVED_DATA)
build\:dev:
	@$(DEV_OPERATION_LOCK); \
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(DEV_FLAGS) build; \
	codesign --verify --deep --strict '$(APP)'; \
	test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$(APP)/Contents/Info.plist')" = chiimagnus.bailey.dev

build\:release: CONFIGURATION = Release
build\:release: build

build\:ui: SCHEME = Bailey-UI
build\:ui: DERIVED_DATA = $(DEV_DERIVED_DATA)
build\:ui:
	@$(DEV_OPERATION_LOCK); \
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(DEV_FLAGS) build-for-testing

test\:ui: SCHEME = Bailey-UI
test\:ui: DERIVED_DATA = $(DEV_DERIVED_DATA)
test\:ui:
	@$(DEV_OPERATION_LOCK); \
	$(SELECTED_TESTS_PREFLIGHT); \
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(DEV_FLAGS) $(TEST_SELECTION) test

test: DERIVED_DATA = $(DEV_DERIVED_DATA)
test:
	@$(DEV_OPERATION_LOCK); \
	$(SELECTED_TESTS_PREFLIGHT); \
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(DEV_FLAGS) $(TEST_SELECTION) test; \
	if [ '$(SIGNING)' = adhoc ]; then \
		for bundle in '$(APP)' '$(APP)/Contents/PlugIns/BaileyTests.xctest'; do \
			codesign --verify --deep --strict "$$bundle"; \
			codesign -dvvv "$$bundle" 2>&1 | grep -Fx 'Signature=adhoc' >/dev/null; \
		done; \
	fi

test\:%:
	@test -n "$(strip $(subst $(comma), ,$*))" || { echo '请指定 XCTest 类名' >&2; exit 2; }
	@$(MAKE) --no-print-directory test ONLY_TESTING="$(addprefix BaileyTests/,$(subst $(comma), ,$*))"

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
		for bundle in "$$app" "$$temp/unpacked/Bailey.app"; do \
			info="$$bundle/Contents/Info.plist"; \
			codesign --verify --deep --strict "$$bundle"; \
			codesign -d --extract-certificates="$$temp/cert-" "$$bundle"; \
			fingerprint=$$(shasum -a 1 "$$temp/cert-0" | awk '{print toupper($$1)}'); \
			test "$$fingerprint" = '$(SIGNING_IDENTITY)'; \
			openssl x509 -inform DER -in "$$temp/cert-0" -checkend 0 -noout; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$info")" = chiimagnus.bailey; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$$info")" = Bailey; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$$info")" = bailey; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$info")" = '$(VERSION)'; \
			test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$info")" = '$(BUILD_NUMBER)'; \
			lipo "$$bundle/Contents/MacOS/bailey" -verify_arch arm64; \
			signature=$$(codesign -dv --verbose=4 "$$bundle" 2>&1); \
			printf '%s\n' "$$signature" | grep -Fx 'TeamIdentifier=$(SIGNING_TEAM)' >/dev/null; \
			printf '%s\n' "$$signature" | grep '^Authority=Apple Development:' >/dev/null; \
		done; \
		mv "$$temp/package.zip" '$(ARCHIVE)'; \
		printf '已验证发布包：%s\n' '$(ARCHIVE)'

clean:
	$(XCODEBUILD) clean
