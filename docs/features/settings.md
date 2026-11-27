# 设置与配置文件

本页维护普通偏好、配置文件和即时应用。新增设置或改变读写方式、默认值、传播路径时更新；
窗口快照见 [session-restore.md](session-restore.md)。

## Invariants

- **`AppSettings.shared` 是唯一生效的应用偏好来源。** View 不另存一份全局设置，
  原生表面由所属窗口应用变更。
- **配置不是工作区备份。** `~/.config/bailey/config.toml` 保存偏好，
  不承载项目快照或未保存文本。
- **写入不能破坏手工配置。** 保存偏好使用原子写入；失败保留原文件。
- **正式版与开发版隔离。** 正式 Debug／Release 共用 `chiimagnus.bailey`；
  测试采用 `chiimagnus.bailey.dev`，不读取或覆盖正式配置、语言、历史和 Bark 钥匙串。

## 设置界面

`⌘,` 打开原生 SwiftUI 设置窗口。左侧按功能分为 Common、Text Editor、Terminal、Browser、
File Manager、Git Manager、Projects，以及连接设置（端口转发、手机通知）；右侧使用系统 `Form`。

Common 设置 System／Light／Dark 外观、明暗 Ghostty 主题和通用面板字号。
Text Editor 设置源码／Diff、CSV／TSV、Markdown 阅读字号及折行；Terminal 设置终端字号、等宽字体家族、光标、Option 和历史。
系统字体家族仅在首次展示 Terminal 字体选择器时枚举，其他页面和 App 启动不预载该列表。

### 字号与内容缩放

| 设置 | 作用范围 | 配置键 | 默认 |
| --- | --- | --- | ---: |
| 面板字号 | Projects、Files、Git Manager | `panel.font-size` | 14 pt |
| 终端字号 | Terminal | `font-size` | 13 pt |
| 编辑器字号 | 所有源码与 Git Diff | `editor.font-size` | 13 pt |
| 表格字号 | CSV／TSV | `table.font-size` | 11 pt |
| 阅读字号 | Markdown 预览 | `reader.font-size` | 16 pt |

通用面板字号范围 9–18 pt，其余 8–32 pt。源码与终端继续共用等宽字体家族，字号独立。
每组字号使用自己的配置键与默认值，调整任一组不影响其他组。
Window 菜单 `⌘+`、`⌘-`、`⌘0` 按当前活动组的实际内容放大、缩小或恢复该组默认值，
不因并排预览指向同一文件而误调源码。HTML／Browser 使用当前 WebView 的页面缩放；
图片／SVG 使用现有图形视口缩放，恢复适应窗口；音视频保留系统控件，无字号命令。
调整立即作用于同类内容，不重建终端、编辑器或预览文档。
Git Manager 提供树／列表布局、工具栏及自部署托管域名映射。
File Manager 只配置 Files 树排除规则；Browser 和 Projects 暂无选项。

恢复默认重置普通偏好，不删除独立隧道、窗口快照或 Bark 凭据。

## Git 设置与托管平台

提交与仓库网页链接见 [Git 托管平台](git-graph.md#托管平台与-git-remotes)。
自部署实例只需在「Self-hosted Git Providers」每行填写 `host=provider`，
例如 `git.company.cn=gitlab`、`code.example.org=gitea`。
配置键为 `git.host-providers = ["git.company.cn=gitlab"]`，
默认空数组，仅在校验通过后保存；自动支持的平台不需要任何设置。

## 文件管理器排除规则

Settings → File Manager 每行输入一个 Glob（`*`、`?`、
`**`），点击「应用」后才进行验证与原子写盘；失败时保留原有有效规则并显示错误。「恢复默认排除规则」恢复 `**/.git`。
`config.toml` 中使用 `files.exclude = ["**/.git", "**/node_modules"]` 形式；
缺少该键默认仅隐藏 `.git`，显式 `files.exclude = []` 则不隐藏任何条目。
设置由 `AppSettings.shared` 唯一持有，变化即时更新 Files 树，绝不影响 Git、
命令面板或以后独立的搜索／监听规则。详情见 [文件可见性](files.md#文件可见性)。

## 设置传播

Git 检出提交的“总是接受”写入 `git.always-accept-checkout`，默认关闭，仅略过游离 HEAD 确认。
Tag 推送前的“以后总是继续”写入 `git.always-proceed-push-tag`，默认关闭，
仅略过远端分支包含关系的启发式警告，不绕过 Git 真实推送权限和错误。
两项偏好独立，重置设置均恢复关闭。

终端字体、配色、光标和 Option-as-Alt 变化即时作用于现有原生表面，不重建 Shell。
只有 `AppSettings.shared` 会将外观和配色同步到整个 App；
独立的 `AppSettings(configURL:)` 可以解析/保存临时配置，却不会改动应用窗口和全局主题。
语言偏好仍写入创建实例时指定的 `UserDefaults`，临时用例须显式使用独立 suite。
主题与控件规范见 [ui.md](../ui.md)。

窗口布局归各自窗口，见 [自由停靠](dock.md#布局与标签)。
旧 `workspace.*` 配置键不再生效；读取时不改原文件，下次保存偏好时不再写入旧键。

字体加粗使用 `terminal.font-thicken`；Git 文件树／列表使用 `git.view-mode`，默认 `tree`。
语言和 Diff 布局偏好另存 UserDefaults，不写入 TOML。

应用语言改变需要重启；重启前由同一个 `WorkspaceApplication` 保存所有窗口快照，
仍不能承诺保存未成功写盘的内容。界面中英文、系统语言跟随和回退规则见 [ui.md](../ui.md#本地化)。

## 隔离与关联数据

正式版使用 `~/.config/bailey/`，普通 Bailey Dev 使用 `~/.config/bailey-dev/`；
语言按 Bundle ID 分域，终端历史与 Bark 钥匙串服务也独立。
`--isolated-ui-test` 隔离每轮窗口快照与终端历史，并跳过保存的隧道；
独立 UI 启动器另以临时主目录隔离 TOML。语言等 UserDefaults 和钥匙串不因临时主目录而自动隔离，
完整边界见 [testing.md](../testing-environment.md#隔离环境)。

隧道规则独立存储在 `tunnels.toml`，不并入普通配置；其生命周期见 [tunnels.md](tunnels.md)。

手机通知与凭据见[通知](notifications.md#手机通知设置)。

## 验证

`AppSettingsTests` 使用临时配置检查默认值、往返、无效类型、旧键清理及写入失败。
`WorkspaceRetentionUITests` 在隔离 Bailey Dev 中通过 ⌘, 切换外观，
核对临时 TOML 写入与重启后界面选项；终端的主题传播仍须验证同一 Shell 进程与原生显示，
不由配置文件变化推断。

实现入口：[AppSettings.swift](../../Bailey/App/AppSettings.swift)。
统一验收见 [testing.md](../testing.md)。
