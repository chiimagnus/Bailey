# Bailey

**简体中文** · [English](README.en.md)

**自由组装的 AI IDE。**

围绕原生终端，在同一个窗口使用代码文件、Git、浏览器和 AI 命令行工具，并自由排列。支持 Apple Silicon，最低 macOS 15.6。

## 能做什么

- **终端与 AI CLI**：使用你习惯的命令行工具，切换面板时保留正在运行的会话。
- **本机与 SSH 项目**：在同一工作区管理本机或远程文件、终端和 Git。
- **代码与差异**：原生编辑、查找、语法高亮，以及统一或分栏 Diff。
- **Git 图谱**：查看提交历史、未提交改动、分支、标签、Stash 和 Worktree。
- **自由布局**：拖动标签组合终端、文件管理器、Git 面板和浏览器。
- **辅助工具**：命令面板、文件搜索、SSH 隧道和可选的手机通知。

## 安装

1. 从 [GitHub Releases](https://github.com/chiimagnus/Bailey/releases) 下载 `bailey-X.Y.Z-macos-arm64.zip`。
2. 打开 Bailey。若 macOS 阻止首次运行，运行:

```sh
xattr -dr com.apple.quarantine "/Applications/Bailey.app"
```

## 更多

- [功能与开发文档](docs/README.md) · [本地构建](docs/development.md)
- [参与开发](CONTRIBUTING.md) · [报告问题](https://github.com/chiimagnus/Bailey/issues) · [安全报告](SECURITY.md)

Bailey 采用 [GPLv3](LICENSE)。项目来源与第三方声明见 [NOTICE.md](NOTICE.md)。
