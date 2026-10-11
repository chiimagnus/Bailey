# Kero

A native terminal workspace for macOS, with projects, SSH, files, Git and diffs.

## Features

- One project list in the left sidebar: add multiple local files or folders with ⇧⌘A
- Add SSH folders or files by host alias and remote path (including Windows with an MSYS2 shell)
- Selecting a project controls its Files/Git context, regardless of terminal `cd`
- Native macOS terminal tabs and split panes
- GPU-accelerated terminal powered by Ghostty
- Local and SSH remote terminal workspaces
- Files, Git status, commits and editable diffs beside the terminal
- Git changes in a collapsible directory tree (default) or flat list, configurable in Settings
- Browser panes and command palette (coding agents run as ordinary terminal programs)

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

To add files or folders, press **Shift+Cmd+A** or use **+** in the bottom-left
corner of the sidebar. The menu also accepts SSH paths; there is no separate
blank-project command. Closing the last window quits Kero and stops its port
forwards; open Kero again to restore saved tabs and projects.
For remote items, choose **+ → Add SSH Files or Folders…**, select a host from
`~/.ssh/config`, and enter one absolute remote path per line. Windows SSH hosts
with an MSYS2 shell accept both `D:\\GitHub\\project` and `/d/GitHub/project`.
Remote connections use your existing SSH keys and OpenSSH config; no port
forwarding or local filesystem mount is needed.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, signing, and localization.

## License

GPLv3. See [LICENSE](LICENSE); existing authors' copyright notices are retained.
