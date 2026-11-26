# Bailey: Xcode 负责构建与测试，Make 只提供统一入口。
.DEFAULT_GOAL := help
.NOTPARALLEL:

PROJECT := Bailey.xcodeproj
SCHEME := Bailey
CONFIGURATION ?= Debug
DESTINATION := platform=macOS,arch=arm64
DERIVED_DATA := .build/DerivedData
DEV_DERIVED_DATA := .build/DerivedData-Dev
DEV_FLAGS := BAILEY_BUNDLE_SUFFIX=.dev 'BAILEY_APP_NAME=Bailey Dev' \
	BAILEY_DOCUMENT_HANDLER_RANK=None 'BAILEY_FINDER_SERVICE_NAME=Add Folder to Bailey Dev'
SOURCE_PACKAGES := .build/SourcePackages
APP_BUNDLE = Bailey.app
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_BUNDLE)
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/Bailey.app
RELEASE_DSYM := $(RELEASE_APP).dSYM
ARCHIVE := .build/releases/bailey-$(VERSION)-macos-arm64.zip
DSYM_ARCHIVE := .build/releases/bailey-$(VERSION)-macos-arm64.dSYM.zip

# 按 Package.resolved 固定版本；与 Xcode 的工程、scheme、测试目标共用。
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIGURATION) -destination '$(DESTINATION)' \
	-derivedDataPath $(DERIVED_DATA) -clonedSourcePackagesDirPath $(SOURCE_PACKAGES) \
	-skipPackageUpdates -disableAutomaticPackageResolution
TEST_SELECTION = $(foreach TEST,$(ONLY_TESTING),-only-testing:$(TEST))
SELECTED_TESTS_PREFLIGHT = if [ -n '$(strip $(ONLY_TESTING))' ]; then \
	enumeration='$(CURDIR)/.build/selected-tests.json'; \
	trap 'rm -f "$$enumeration"' EXIT; \
	rm -f "$$enumeration"; \
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(DEV_FLAGS) $(TEST_SELECTION) \
		-enumerate-tests -test-enumeration-format json -test-enumeration-output-path "$$enumeration" test > /dev/null; \
	python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); full=[g["name"]+"/"+c["name"]+"/"+t["name"].removesuffix("()") for p in j["values"] for g in p.get("children",[]) for c in g.get("children",[]) for t in c.get("children",[]) if t["kind"]=="test" and not t.get("disabled",False)]; missing=[s for s in sys.argv[2].split() if not any(p==s or p.startswith(s+"/") for p in full)]; print("Selected XCTest methods:",len(full)); sys.exit("Unmatched XCTest selector: "+", ".join(missing) if missing else 0)' "$$enumeration" '$(strip $(ONLY_TESTING))'; \
	rm -f "$$enumeration"; \
fi
# Bailey Dev shares its bundle identity and XCTest session across checkouts.
DEV_OPERATION_LOCK = set -eu; mkdir -p '$(CURDIR)/.build'; \
	lock="$$(getconf DARWIN_USER_TEMP_DIR)chiimagnus.bailey.dev-test.lock"; \
	exec 9>"$$lock"; \
	/usr/bin/lockf -s -t 0 9 || { \
		echo '无法取得当前用户的 Bailey Dev 构建／测试锁；请等待已有操作结束。' >&2; exit 2; \
	}; trap 'exit 130' INT; trap 'exit 143' TERM
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
		'  make test SIGNING=adhoc                 临时签名运行宿主 XCTest（隔离环境）' \
		'  make build:release                      Release 构建并验签' \
		'  make build:release SIGNING=adhoc        无开发证书时验证 Release 构建' \
		'  make test ONLY_TESTING="BaileyTests/类名1 BaileyTests/类名2"  运行多个 XCTest 类' \
		'  make package VERSION=X.Y.Z BUILD_NUMBER=N  制作并验证 App 与 dSYM ZIP' \
		'  make clean                              Xcode 清理构建产物' \
		'  make doctor                             检查 Xcode 工具链'

doctor:
	@command -v xcodebuild >/dev/null
	@test -d '$(PROJECT)'
	@xcodebuild -version

build:
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(BUILD_FLAGS) build
	codesign --verify --deep --strict '$(APP)'

build\:dev: DERIVED_DATA = $(DEV_DERIVED_DATA)
build\:dev: APP_BUNDLE = Bailey Dev.app
build\:dev:
	@$(DEV_OPERATION_LOCK); \
	$(XCODEBUILD) $(SIGNING_FLAGS) $(VERSION_FLAGS) $(DEV_FLAGS) build; \
	codesign --verify --deep --strict '$(APP)'; \
	test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$(APP)/Contents/Info.plist')" = chiimagnus.bailey.dev

build\:release: CONFIGURATION = Release
build\:release: BUILD_FLAGS = ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
build\:release: build
	@set -eu; \
		app='$(RELEASE_APP)'; executable="$$app/Contents/MacOS/bailey"; \
		fonts="$$app/Contents/Resources/swiftui-math_SwiftUIMath.bundle/Contents/Resources/mathFonts.bundle"; \
		test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$app/Contents/Info.plist")" = chiimagnus.bailey; \
		if xcrun size -m "$$executable" | grep -q '^Segment __LLVM_COV:'; then \
			echo 'Release 仍包含测试覆盖率数据' >&2; exit 1; \
		fi; \
		test -f "$$fonts/latinmodern-math.otf" && test -f "$$fonts/latinmodern-math.plist"; \
		temp=$$(mktemp -d '.build/.release-sign.XXXXXX'); \
		trap 'rm -f "$$temp"/cert-*; rmdir "$$temp"' EXIT; \
		if codesign -dv "$$app" 2>&1 | grep -q '^Signature=adhoc$$'; then \
			identity=-; \
		else \
			codesign -d --extract-certificates="$$temp/cert-" "$$app"; \
			identity=$$(shasum -a 1 "$$temp/cert-0" | awk '{print toupper($$1)}'); \
		fi; \
		find "$$fonts" -type f \( -name '*.otf' -o -name '*.plist' \) \
			! -name 'latinmodern-math.otf' ! -name 'latinmodern-math.plist' -delete; \
		rm -f "$$fonts/math_table_to_plist.py"; \
		xcrun strip -x "$$executable"; \
		codesign --force --sign "$$identity" $(if $(strip $(SIGNING_KEYCHAIN)),--keychain '$(SIGNING_KEYCHAIN)') \
			--preserve-metadata=entitlements,requirements,flags,identifier "$$app"; \
		codesign --verify --deep --strict "$$app"; \
		printf '已精简并验签 Release：'; du -sh "$$app"

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
test: APP_BUNDLE = Bailey Dev.app
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
	@test ! -e '$(DSYM_ARCHIVE)' || { echo '符号包已存在，拒绝覆盖：$(DSYM_ARCHIVE)' >&2; exit 1; }
	@$(MAKE) --no-print-directory 'build:release' SIGNING=release VERSION='$(VERSION)' BUILD_NUMBER='$(BUILD_NUMBER)'
	@mkdir -p .build/releases
	@set -eu; temp=$$(mktemp -d .build/releases/.verify.XXXXXX); trap 'rm -rf "$$temp"' EXIT; \
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
		uuid=$$(xcrun dwarfdump --uuid "$$temp/unpacked/Bailey.app/Contents/MacOS/bailey" | awk '{print $$2}'); \
		test -n "$$uuid" && test "$$uuid" = "$$(xcrun dwarfdump --uuid '$(RELEASE_DSYM)' | awk '{print $$2}')"; \
		ditto -c -k --keepParent '$(RELEASE_DSYM)' "$$temp/symbols.zip"; \
		ditto -x -k "$$temp/symbols.zip" "$$temp/symbols"; \
		test "$$uuid" = "$$(xcrun dwarfdump --uuid "$$temp/symbols/Bailey.app.dSYM" | awk '{print $$2}')"; \
		mv "$$temp/package.zip" '$(ARCHIVE)'; \
		mv "$$temp/symbols.zip" '$(DSYM_ARCHIVE)'; \
		printf '已验证发布包：%s\n已验证符号包：%s\n' '$(ARCHIVE)' '$(DSYM_ARCHIVE)'

clean:
	$(XCODEBUILD) clean
