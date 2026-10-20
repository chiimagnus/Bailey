# Bailey

**自由组装的 AI IDE。**

在原生终端工作区中，让 CLI、项目文件、Git 和浏览器在同一窗口协作。

支持 Apple Silicon Mac，最低 macOS 15.6。界面使用 SwiftUI 与 AppKit，终端由 Ghostty 驱动，文件与 Diff 使用原生 TextKit 编辑器。

## 功能

| 使用场景 | Bailey 提供什么 |
| --- | --- |
| 多项目工作 | 添加本机文件夹或 SSH 文件／目录，Files／Git 跟随项目范围；可独立打开项目外文件 |
| 组织工作区 | 自由组合终端、文件、Diff、浏览器与工具面板，移动标签保留内容 |
| 编辑与审查 | 文件编辑、查找、撤销、事件驱动保存，统一／分栏 Diff |
| Git 操作 | 查看提交关系、未提交修改和工作树；右键管理提交、分支、标签、储藏与历史文件 |
| 使用开发服务 | 内置浏览器及独立配置的长期 SSH 隧道 |
| 快速定位 | ⌘P 命令面板、本机项目文件搜索和终端会话切换 |
| 继续工作 | 恢复项目、标签和停靠布局，可选回放终端历史 |
| 手机提醒 | 可选将 Codex 等终端程序的通知通过 Bark 推送到 iPhone |

恢复布局不等于恢复运行中的命令、未保存文本或网页表单。SSH 文件操作依赖远端 POSIX shell 和相应工具；Windows 使用 MSYS2 环境。能力与边界见[功能文档](docs/README.md#功能文档)。

## 安装

1. 从 [GitHub Releases](https://github.com/chiimagnus/Bailey/releases) 下载 `bailey-版本-macos-arm64.zip`。
2. 解压，将 `Bailey.app` 放入 `/Applications`。
3. 打开应用。确认包来自可信的维护者发布后，若被下载隔离属性拦截，仅对这个 App 执行：

```sh
xattr -dr com.apple.quarantine "/Applications/Bailey.app"
open "/Applications/Bailey.app"
```

已有 Bailey 正在运行时，先自行保存工作；替换磁盘上的 App 不代表当前进程已经使用新版本。签名与首次运行说明见 [signing.md](docs/signing.md)。

## 开始使用

通过「文件 → 添加文件夹」（⇧⌘A）建立本机项目，或使用「添加 SSH 文件或文件夹」选择远端目标。添加目录只创建项目，不会自动启动终端。已有项目时，从「文件 → 打开文件…」（⌘O）或各停靠组标签栏「＋ → 打开文件…」选取单个／多个 Mac 文件，直接在当前项目的编辑标签中打开，不改变项目目录、Files／Git 根或终端工作位置；无项目时先添加文件夹。

在 Finder 右键选择「打开方式 → Bailey」，或使用 `open -a Bailey /path/to/file`，可以打开本机文件；支持文本、源码和图片预览，目录仍作为项目添加。Bailey 只注册为备用程序，不修改系统默认打开方式：只有用户主动设置 Bailey 为默认程序后，Finder 双击才会直接交给 Bailey。再次打开已在 Bailey 某项目／某窗口编辑的文件，会回到原项目、原窗口、原标签，无论文件实际位于哪个目录；此前未打开的文件则进入当前项目。原 Finder「Add Folder to Bailey」服务仍仅添加目录。未知扩展名可在 Finder 的「其他…」中手动选择 Bailey，能否编辑仍取决于文件内容。

Finder 拖放按落点操作：拖进**Projects** 时文件直接打开为当前项目的标签，文件夹才添加为项目；拖进**File Manager** 会复制到目标目录（目录行→该目录，文件行→其父目录，根标题／留白→项目根目录），源文件保留，同名目标不覆盖；拖到**顶部标签栏或编辑区**打开文件或激活已有标签；分屏时新标签进入实际拖入的标签栏，已有标签保持原位置。拖到**本机终端**只插入经过转义的路径，**不会执行命令**；网页内容的文件上传仍由 WebKit 接管。远端 SSH 文件树不接受本机 Finder 复制，SSH 终端不把 Mac 路径当远端文件，也不自动上传。

在标签栏的「＋」可打开文件、创建文件／文件夹或添加终端、浏览器和面板，拖动它们组织工作区。Files 与 Git 使用当前项目范围，不因临时打开项目外的文件而改变。

打开「Git 管理器」，单击提交或其标签展开历史详情；同一提交的其他分支和 Git 标签（Tag）可从「+N」找到。右键未检出的本地分支，选择「创建工作树…」；已检出的分支右键「工作树」，可在 Bailey 中打开、复制路径或移除；无匹配分支时，右键独立的工作树小图标。本机还可在访达中定位。

移除工作树不会删除分支。主工作树、存在未提交修改或仍在使用的工作树不能移除。其他工具修改本机或 SSH 仓库时，Git 面板在 Bailey 前台可见期间会自动刷新；网络慢时可手动刷新。详情见 [Git 功能说明](docs/features/git.md#本地分支与归档)。

常用快捷键：⌘O 打开文件，⇧⌘A 添加项目文件夹，⌘T 新建终端，⌘N 新建文件，⌘S 保存聚焦内容，⌘P 打开命令面板，⇧⌘N 新建窗口。界面支持英语和简体中文。

需要手机提醒时，在「设置 → 手机通知」逐条添加 Bark HTTPS 推送链接（也可直接填写官方设备 Key）。支持多个设备及自建 HTTPS Bark 服务器，可单独移除地址；「发送测试通知」会尝试向所有地址推送。Bailey 只转发终端主动发出的通知（例如 Codex 的 OSC 9），不转发普通终端响铃；不支持手机回复。推送内容会经过各自配置的 Bark 服务器，可能包含敏感终端输出。

## 数据与权限

普通设置位于 `~/.config/Bailey/config.toml`，长期隧道位于同目录的 `tunnels.toml`。Bark 推送地址及设备 Key 保存在 macOS 钥匙串，不写入配置文件。终端历史回放默认关闭；启用后其中可能包含私人输出。工作区快照不保存尚未成功写盘的编辑内容。

终端程序读取剪贴板须经确认，SSH 使用已有配置与密钥。不要把包含凭据的日志或录屏贴到公开 Issue；安全问题按 [SECURITY.md](SECURITY.md) 私下报告。

## 从源码构建

工具链、本机构建、签名、依赖和安装见 [docs/development.md](docs/development.md)。[docs/README.md](docs/README.md) 索引架构、开发规范、测试、UI 及各功能的维护文档。

## 参与开发

先读 [CONTRIBUTING.md](CONTRIBUTING.md)，确认需求再实现，提交时填写 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md)。人工贡献者和 AI 都遵守 [AGENTS.md](AGENTS.md)；验证结果和未测范围必须可检查。

## 项目来源与许可

项目 fork 自 [benjaminv/kero](https://github.com/benjaminv/kero)，最初来源于 [egoist/kero](https://github.com/egoist/kero)，现独立维护。文档管理体系参考 Tinycast，来源与第三方声明见 [NOTICE.md](NOTICE.md)。

采用 [GPLv3](LICENSE)，保留原有版权与署名。
