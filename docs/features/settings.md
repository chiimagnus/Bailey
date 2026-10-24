# 设置与配置文件

本页维护普通偏好、工作区初始值、配置文件和即时应用。新增设置或改变读写方式、默认值、传播路径时更新；窗口快照见 [session-restore.md](session-restore.md)。

## Invariants

- **`AppSettings.shared` 是唯一生效的应用偏好来源。** View 不另存一份全局设置，原生表面由所属窗口应用变更。
- **配置不是工作区备份。** `~/.config/bailey/config.toml` 保存偏好和布局初始值，不承载项目快照或未保存文本。
- **写入不能破坏手工配置。** 保存偏好使用原子写入并保留手工调整的工作区字段；失败保留原文件。
- **初始布局只影响新项目。** 已有项目按自己的停靠状态恢复，不因设置改变被重置。
- **正式版与开发版隔离。** 正式 Debug／Release 共用 `chiimagnus.bailey`；测试采用 `chiimagnus.bailey.dev`，不读取或覆盖正式配置、语言、历史和 Bark 钥匙串。

## 设置界面

`⌘,` 打开原生 SwiftUI `Settings` 场景。窗口采用简单的 `NavigationSplitView` 两栏：左侧按「偏好设置」（通用、终端、工作区）和「连接」（端口转发、手机通知）分组，右侧使用独立滚动的系统 `Form`。隔离测试模式不展示手机通知。现有偏好直接绑定 `AppSettings`，Bark 钥匙串与隧道管理保留原有实现；不新增搜索、历史导航、窗口缩放或新的设置功能。

## 布局配置

窗口协调者将初始配置显式传给项目，项目不自行读取全局布局。检查组数量、权重、选中项、工具唯一性和必需项；边缘范围为 `0.05...0.4`。无效工作区配置整体退回默认值并记录错误，不能部分应用。

## 设置传播与旧键

Git 检出提交的“总是接受”写入 `git.always-accept-checkout`，默认关闭，仅略过游离 HEAD 确认。Tag 推送前的“以后总是继续”写入 `git.always-proceed-push-tag`，默认关闭，仅略过远端分支包含关系的启发式警告，不绕过 Git 真实推送权限和错误。两项偏好独立，重置设置均恢复关闭。

终端字体、配色、光标和 Option-as-Alt 变化即时作用于现有原生表面，不重建 Shell。只有 `AppSettings.shared` 会将外观和配色同步到整个 App；独立的 `AppSettings(configURL:)` 可以解析/保存临时配置，却不会改动应用窗口和全局主题。语言偏好仍写入创建实例时指定的 `UserDefaults`，临时用例须显式使用独立 suite。主题与控件规范见 [ui.md](../ui.md)。

现行字体加粗键为 `terminal.font-thicken`；不再读取旧字体 UserDefaults 或旧 `font-thicken` 键。语言及 Diff 偏好使用的现有 UserDefaults 不属于旧字体迁移，不能一起删除。

应用语言改变需要重启；重启前由同一个 `WorkspaceApplication` 保存所有窗口快照，仍不能承诺保存未成功写盘的内容。界面中英文、系统语言跟随和回退规则见 [ui.md](../ui.md#本地化)。

## 隔离与关联数据

正式版使用 `~/.config/bailey/`，普通 Bailey Dev 使用 `~/.config/bailey-dev/`；语言按 Bundle ID 分域，终端历史与 Bark 钥匙串服务也独立。`--isolated-ui-test` 隔离每轮窗口快照与终端历史，并跳过保存的隧道；独立 UI 启动器另以临时主目录隔离 TOML。语言等 UserDefaults 和钥匙串不因临时主目录而自动隔离，完整边界见 [testing.md](../testing.md#隔离环境)。

隧道规则独立存储在 `tunnels.toml`，不并入普通配置；其生命周期见 [tunnels.md](tunnels.md)。

「手机通知」支持逐条添加、移除多个 Bark HTTPS 推送地址（或填写官方设备 Key），并对所有已配置地址发送测试通知。支持官方及自建 HTTPS Bark 服务器。设备 Key 与地址列表统一存于 macOS 钥匙串，配置文件、日志和实际请求 URL 均不包含 Key；界面只展示主机名和 Key 后四位。地址列表为空时不推送；普通设置重置不删除钥匙串凭据，需逐条明确移除。`--isolated-ui-test` 隔离实例不访问手机通知设置，也不转发通知，避免触及用户真实凭据和设备。

## 验证

`AppSettingsTests` 使用临时配置检查默认值、往返、无效类型、手工布局保留及写入失败。`WorkspaceRetentionUITests` 在隔离 Bailey Dev 中通过 ⌘, 切换外观，核对临时 TOML 写入与重启后界面选项；终端的主题传播仍须验证同一 Shell 进程与原生显示，不由配置文件变化推断。

实现入口：[AppSettings.swift](../../Bailey/App/AppSettings.swift)。统一验收见 [testing.md](../testing.md)。
