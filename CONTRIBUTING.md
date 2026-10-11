# Developing Kero

## Build

Requires Xcode, macOS 15.6+ and the personal Apple Development certificate
in the login Keychain. There is one target and one app, **Kero.app**
(bundle ID `sh.kero`), with a single Debug build configuration.

```sh
git clone --recurse-submodules https://github.com/chiimagnus/kero.git
cd kero
./scripts/prepare-ghostty.sh # One-time verified download; keep the binary in Vendor/GhosttyKit
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackageUpdates build
codesign --verify --deep --strict 'build/DerivedData/Build/Products/Debug/Kero.app'
```

To check Files expansion across project/root changes with the real local backend:

```sh
xcrun swiftc -swift-version 5 -o build/check-file-tree-navigation \
  kero/Workspace/WorkspaceBackend.swift kero/Workspace/FileTreeModel.swift \
  scripts/check-file-tree-navigation.swift && build/check-file-tree-navigation
```

The app uses the personal Apple Development certificate for team
`RDQHYSDFFG`, and saves its configuration in `~/.config/kero/config.toml`.
This is for local use, not distribution or notarization.

Open `kero.xcodeproj` and press **Cmd+B** for normal development. If only
the Xcode beta is installed, set
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## Localization

The app uses Xcode String Catalogs for localization; see
[LOCALIZATION.md](LOCALIZATION.md).

There is no automatic updater or publishing pipeline. Build and launch locally
after reviewing the changes and verifying the signature.
