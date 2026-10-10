# Kero

A native terminal workspace for macOS, with projects, SSH, files, Git and diffs.

## Features

- Native macOS project sidebar, tabs and split panes
- GPU-accelerated terminal powered by Ghostty
- Local and SSH remote terminal workspaces
- Files, Git status, commits and editable diffs beside the terminal
- Browser panes, command palette and coding-agent workflows

## Build locally

Requires macOS 15.6+, Xcode and an Apple Development signing identity.
This fork provides local source builds, not prebuilt downloads or automatic updates.

```sh
git clone --recurse-submodules https://github.com/chiimagnus/kero.git
cd kero
xcodebuild -project kero.xcodeproj -scheme kero -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open 'build/DerivedData/Build/Products/Release/Kero Remote.app'
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, signing, and localization.

## License

GPLv3. See [LICENSE](LICENSE); existing authors' copyright notices are retained.
