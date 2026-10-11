# Kero

A native terminal workspace for macOS, with projects, SSH, files, Git and diffs.

## Features

- One project list in the left sidebar: add multiple local files or folders with ⇧⌘A
- Add SSH folders or files by host alias and remote path (including Windows with an MSYS2 shell)
- Selecting a project controls its Files/Git context, regardless of terminal `cd`
- Files remembers expanded folders per project and compacts single-child folder chains such as `BinaryTarget / GhosttyKit.xcframework`; Git keeps folder folds per repository when switching
- Native macOS terminal tabs and split panes
- GPU-accelerated terminal powered by Ghostty
- Local and SSH remote terminal workspaces
- Files, Git status, commits and editable diffs beside the terminal
- Files, Git changes/staged changes, and committed files use the same tree interaction and vertical guides; long names scroll inside the row so fixed controls stay visible
- Files colors Git state in the name: modified yellow, added/untracked green, deleted red, renamed/copied blue, conflict purple, ignored gray
- Git changes in a directory tree (default) or flat list, configurable in Settings
- Browser panes and command palette (coding agents run as ordinary terminal programs)

## Build locally

Requires macOS 15.6+, Xcode and a personal Apple Development certificate.
Kero has one local app: **Kero.app**, built in **Debug**. No publishing pipeline.

```sh
git clone --recurse-submodules https://github.com/chiimagnus/kero.git
cd kero
./scripts/prepare-ghostty.sh
open kero.xcodeproj
```

`prepare-ghostty.sh` downloads the pinned GhosttyKit only when it is missing, keeps it under `Vendor/GhosttyKit`, and reuses it on later builds. Press **Cmd+B** in Xcode for normal development; see [CONTRIBUTING.md](CONTRIBUTING.md) for the canonical command-line build and verification steps.
To add files or folders, press **Shift+Cmd+A** or use **+** in the bottom-left
corner of the sidebar. The menu also accepts SSH paths; there is no separate
blank-project command.
For remote items, choose **+ → Add SSH Files or Folders…**, select a host from
`~/.ssh/config`, and enter one absolute remote path per line. Windows SSH hosts
with an MSYS2 shell accept both `D:\\GitHub\\project` and `/d/GitHub/project`.
Remote connections use your existing SSH keys and OpenSSH config; no port
forwarding or local filesystem mount is needed.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, signing, and localization.

## License

GPLv3. See [LICENSE](LICENSE); existing authors' copyright notices are retained.
