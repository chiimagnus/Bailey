# Developing Kero

## Build

Requires Xcode, macOS 15.6+ and the personal Apple Development certificate in
the login Keychain. Only Ghostty is used; there is no Rust or release pipeline.

```sh
git clone --recurse-submodules https://github.com/chiimagnus/kero.git
cd kero
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

For a locally signed production build, use:

```sh
xcodebuild -project kero.xcodeproj -scheme kero -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
codesign --verify --deep --strict 'build/DerivedData/Build/Products/Release/Kero Remote.app'
```

Both configurations sign with the installed Apple Development identity for
team `RDQHYSDFFG`. This is for local development, not distribution to other Macs:
Developer ID Application signing and notarization would require a different
certificate and workflow. The Release app keeps bundle ID `sh.kero.remote` to
preserve the installed app's settings. The separate Debug app uses `sh.kero.dev`,
its own icon, and `~/.config/kero-dev/config.toml`.

Open `kero.xcodeproj` and press **Cmd+B** for normal development. If only the
Xcode beta is installed, set
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## Website and localization

The site is in [`web/`](web/README.md); English/Chinese user docs are under
`web/content/docs`. The app uses Xcode String Catalogs for localization; see
[LOCALIZATION.md](LOCALIZATION.md). The site requires Bun, not the macOS app.

There is no automatic updater or publishing pipeline. Build and launch locally
after reviewing the changes and verifying the signature.
