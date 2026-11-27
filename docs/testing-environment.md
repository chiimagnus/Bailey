# 测试环境与隔离

维护测试实例、真实 GUI／SSH 夹具及清理边界。测试完成标准和入口见 [testing.md](testing.md)。

## 隔离环境

同一用户的 Bailey Dev 构建、宿主测试与 GUI 测试不能并行，即使使用不同工作树或 DerivedData：
它们共用 Bundle ID 和系统 XCTest 会话。四个 Makefile 入口（`build:dev`、`test`、`build:ui`、`test:ui`）通过用户临时目录中的原生文件锁互斥；
已有操作时立即报错，不等待或终止其他进程。持锁进程退出后系统自动释放，不需要删除锁文件。
绕过 Makefile 或使用旧版构建入口的操作仍须人工协调；其他 GUI 测试也不得争用桌面焦点。
`automationmodetool` 在 GUI 测试结束后可能显示 Automation Mode 已关闭；
**不要仅凭状态就判定无法测试**，
先直接运行受影响的 `make test:ui ONLY_TESTING=...` 重新发起系统授权，再根据实际运行结果判断。
管理员免认证策略不是开启 Automation Mode 的命令，不应为一次普通验收擅自修改。

宿主 `Bailey` Scheme 的 TestAction 向测试宿主传入 `--isolated-ui-test`。
`BaileyInstanceMode` 识别该参数或合法 UUID 的 `BAILEY_UI_TEST_RUN_ID`；
隔离快照使用专用 UserDefaults suite，终端历史使用临时路径。
Makefile 的测试构建使用独立 Bundle ID `chiimagnus.bailey.dev`；
独立 UI Test 显式通过 `XCUIApplication(bundleIdentifier:)` 启动 Bailey Dev，
并传入 `--isolated-ui-test` 与一次性 `BAILEY_UI_TEST_RUN_ID`；
不允许定位或终止正式 Bailey。验证 Bailey 快照重启时保留同一测试 UUID，
并通过系统「新建窗口」建立真实场景。

需要单独检查原生界面时使用相同签名的 Debug 包：

```sh
open -n -a "$PWD/.build/DerivedData-Dev/Build/Products/Debug/Bailey Dev.app" --args --isolated-ui-test
```

该模式为每个进程使用独立 UUID 快照和临时终端历史，不加载其他测试实例的项目，不启动已保存隧道。
仅隔离测试模式禁用 SwiftUI 系统场景恢复，防止继承上一轮测试的窗口；
正常应用的窗口恢复不变。隔离模式不自动呈现窗口，应用激活后通过已有 SwiftUI 开窗动作请求一次；
测试直接断言只有一个窗口，不允许在启动等待超时后补发 `⌘⇧N` 掩盖缺窗故障；
不得改为 `open -n` 后按 Bundle ID 附着（可能另起非隔离 Dev，污染普通会话快照）。
**开发版与正式版拥有不同 Bundle ID、配置路径和 DerivedData**，XCUITest 仅定位 Bailey Dev；
正式版运行时也可执行宿主测试，无须强制退出用户 App。`make build:ui` 只编译。
完整 UI 测试仍依赖当前 macOS 图形会话的前台键盘焦点；如果用户同时在其他应用或正式 Bailey 输入，
XCUI 键盘事件可能失败或打断用户，不能将不同 Bundle ID 冒称独立桌面。隔离 Bailey Dev 不再拦截 `⌘Q`：
完整 App 测试实际验证保存失败否决退出、修复后正常退出以及原会话重启恢复；
宿主测试不以跨进程快捷键模拟真实退出。

正式版与普通 Dev 的持久化路径见[设置](features/settings.md#隔离与关联数据)。
独立 UI 启动器使用临时 `HOME` 和 `CFFIXED_USER_HOME`，并核对 App 的 TOML 确实位于临时目录；
仅改 `HOME` 不会改变 Foundation 的主目录。
获授权的 Windows SSH GUI 测试只在一次性测试主目录中引用 `windows-tailscale` 别名，
统一使用经 Tailscale 网络直连的 Windows OpenSSH，不通过 Cloudflare SSH／Access 代理。
当前验收不依赖夹具中历史遗留的 Cloudflare 缓存链接，不复制令牌、
不修改用户 SSH 配置，不借用用户 master。测试结束只解除自己的链接，正式设置保持隔离。
没有授权时不得连接测试主机。
GUI 添加远端项目使用窗口内 `SSHFolderPickerView` 的主机、路径与确认控件，
不再查找旧版系统 Sheet 的 `comboBox` 和 `textView`。
**普通 UI 方法各自使用独立的 Bailey Dev 进程和临时数据**。
测试前通过 `WorkspaceUITestSupport.launch(in:project:)` 将所属临时目录交给已有的
`addLocalFolders()` 初始化工作区；不为非文件选择器测试反复点击 Add Folder、
输入路径和等待原生 Sheet。仅验证真实添加目录、打开文件及原生选择器的用例才操作这些界面。
同一测试方法再次请求相同实例时复用当前窗口，不隐式删除项目；
每例结束时终止自己的 Dev 实例并清理临时主目录，不再遍历 Projects 菜单逐个关闭。
每例仍拥有独立的文件夹、剪贴板恢复、输入法恢复和失败报告。
主动验证重启／退出的用例继续实际重启，不能靠进程复用冒充。
外观、面板字号等 TOML 夹具可经真实 App 验证，不修改现有 Dev 配置。
Git 夹具在自身仓库配置身份和不签名策略，不依赖用户的全局 Git 设置。

临时主目录不等于 UserDefaults／钥匙串全部隔离。语言持久化等设置仍须独立登录账户或明确的按键恢复；
进程内组件测试继续显式使用临时配置与 UserDefaults suite，
Diff 重载测试只使用隔离布局偏好，直接验证工作区编辑状态和干净快照刷新。
临时文件、Git 仓库和受控后端不得指向正式项目。

需要保留不同构建产物时可指定独立 `DERIVED_DATA`，不得清理其他任务的目录；
Dev 四入口仍须持有同一锁，换目录不能隔离同 Bundle ID 的应用、Runner 或桌面。

## Finder 与菜单夹具

Finder 拖进运行中 Bailey 时，
**先核对 Finder 与 Bailey 两个窗口的屏幕边界，目标点不能落在 Finder 自身窗口或侧栏内**，
否则会被 Finder 执行移动／废纸篓等本机操作，不能归因于 Bailey。
隔离 GUI 测试必须根据当前屏幕和真实目标点，通过 XCTest 的原生鼠标操作调整 Finder 来源窗口，
优先利用目标旁的空白区域，确有必要才缩放；UI Runner 沙盒不能直接读写 Finder 的跨进程 AX 窗口属性。
无法露出目标时，必须在拖动文件**之前**失败，不能继续执行可能误移动本机文件的拖放。
调整后仍须核对 Finder 不遮挡目标，并验证实际文件、终端或网页结果。
核对系统当前选中项与拖动的真实 provider 数量；
双窗口、文件树精确行和网页上传必须检查最终编辑标签／Shell／网页内容，而不是只看鼠标事件已派发。

Finder「打开方式」、Dock 文件投递和 `open -a Bailey` 仍指向正式 `chiimagnus.bailey`。
对测试版发送文件时，必须显式使用
`open -n -a "$PWD/.build/DerivedData-Dev/Build/Products/Debug/Bailey Dev.app" --env "BAILEY_UI_TEST_RUN_ID=$UUID" "$TEMP_FILE"`；
不能只传 `--isolated-ui-test` 或混用 `--args`（可能丢失系统文件事件）。
随后核对接收 PID 的 Bundle ID 为 `chiimagnus.bailey.dev`，并检查窗口数、目标文件内容和原始 SHA-256。
Dev 的 `LSHandlerRank=None` 不竞逐 Finder 默认文件处理程序；
Bundle ID 分离不隔离 GUI 焦点，不能因此把物理 Dock 拖放视为已验收。
正式 Bailey 窗口若遮挡 Dev，须在独占图形会话中重验，不得操作正式 App 来迁就测试。

右键菜单由自身的原生快捷键执行动作，不把按键重投给系统菜单栏。
真实 GUI 验收须核对快捷键在菜单打开时操作右键目标、菜单关闭后恢复普通命令目标；
不能把系统 Panel 菜单高亮或菜单项可见当作执行成功。
XCUITest 的 `app.menus` 快照可能漏掉跟踪中的弹出菜单，必要时用录屏和最终结果复核。
剪贴板断言须等待实际内容更新，不能在发送按键后立即读取旧值。

需要点击真实菜单项的测试仍必须证明该项存在、可执行，并核对最终副作用。
菜单树包含不可见的系统主菜单，弹出菜单还会改变元素排序；
实际点击的 GUI 夹具应按可见菜单的稳定标识与非零 frame 定位，
不能缓存 `app.menus.allElementsBoundByIndex` 的临时序号后再点击。
Git 引用刷新会使多级原生菜单失效；即使旧 AX 元素仍报告 `isHittable`，也不能据此执行过期动作。
先结束失效菜单，再从新引用状态重新找到操作项，并检查实际目标项目和 Git 字节。
菜单快捷键已执行并主动结束 tracking 后，不要再发送多余的 Escape：
它可能抵达已恢复焦点的交互式 Bash，成为下一字符的 Meta 前缀，改变命令字节。
打开应用设置时应从 Bailey 的应用菜单定位 `Settings…`，不能用全局
`app.menuItems` 模糊查找 `Settings`（它可能匹配 Apple 菜单的 `System Settings…`）。
Projects 的本机选目录是原生文件选择面板，而“Add SSH Files or Projects”打开的是
当前窗口内的 `SSHFolderPickerView` 覆盖层；两条 UI 测试分别核验原生 sheet 与
`bailey.sshFolderPicker.dismiss`／真实取消结果，不得将 SSH 覆盖层误判成 sheet。

## 授权 SSH 回归

真实 SSH 宿主测试只使用专用且获准的测试 master，不借用用户连接或结束其后台任务。
完整 App UI Runner 的沙盒不允许监听 OpenSSH 的 `/tmp` 控制套接字，
因此 `WorkspaceGitUITests` 的夹具明确禁用多路复用，独立握手；
Tailscale SSH 连接失败不得算作测试通过或回退 Cloudflare SSH；
失败后须核对测试专属远端目录是否残留。


真实 Windows SSH 回归必须**明确指定获授权的测试主机**。
`BAILEY_P4_TEST_SSH_HOST` 是已有的共用参数名，Git 外部刷新与 Markdown 资源实测也使用它；
未提供时专用用例按条件跳过，不能视为真实 SSH 验收。

真实 Windows 实机宿主测试统一通过已授权 `windows-tailscale` SSH 别名执行：

```sh
BAILEY_P4_TEST_SSH_HOST=windows-tailscale TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows-tailscale make test
```

必须核对 XCTest 实际执行数、零失败及目标 Windows SSH 用例的 passed 记录；
目标 SSH 用例不得跳过，其他按环境启用的用例如有跳过须单列说明。
不能以不带环境参数的绿色 `make test` 冒充实机验收。未经授权的自动化测试不得擅自连接用户设备。
XCUITest 只允许启动 Bailey Dev；它不会因 Bundle ID 与正式版冲突而结束正式应用，
但键盘与鼠标仍属于共享图形会话，用户持续输入时必须在独立 GUI 登录会话验收。

只清理本次创建且可确认归属的窗口、进程和数据，不按 App 名或宽泛目录清理。

## 原生 GUI 夹具

`BaileyUITests` 通过一次性本机临时文件／Git 仓库作为输入，并经真实 App 的系统文件选择器、
Dock 和键盘操作核对结果。夹具创建时即登记 XCTest 清理，失败启动也不能留下文件；
Git 子进程使用当前 Xcode 或 Command Line Tools 的真实 Git 二进制，
绕开 `/usr/bin/git` 在 XCTest 沙盒中的 `xcrun` 包装器；标准输出和错误输出分别写入一次性文件，
避免管道反压，并用于核对真实 Git 结果。原生文件选择器在「前往文件夹」中粘贴完整路径并核对解析结果，
需要写入剪贴板的测试须完整保留并恢复其全部项目和数据类型；
不使用剪贴板的 Finder／SSH 拖放测试可声明 `clipboardIsReadOnly`，只核对版本号不变，
避免读取或改写系统无法序列化的延迟剪贴板类型。
用窗口内的 `OKButton` 标识确认、`Escape` 取消，
不能硬编码英文 `Add`/`Open`/`Cancel` 文案。
Files/Git 行用原绝对／仓库相对路径的 AX 标签后缀区分同名项，
文件 Tab 以独立的 AX 路径值区分重名标题，标识符不携带长路径；
多窗口查询必须固定目标窗口的 AX `identifier`；窗口列表的索引会因激活及系统文件投递变化，
不能将 `allElementsBoundByIndex` 的窗口引用跨事件复用。
中文界面与超长 Unicode 文件树路径均有独立 App 回归；系统「前往文件夹」的超长中文路径仍须单独验证，
不由普通路径测试推断。构建 UI Target 不等于执行 GUI 测试。

不使用 `-ApplePersistenceIgnoreState YES`，该参数会干扰原生窗口生命周期与恢复。
已有 Bailey Dev 实例时明确失败而不终止进程，也不允许整套 XCUITest 全部跳过却返回假绿色；
本机 GUI Runner 必须使用 Apple Development 签名而非强制 ad-hoc，否则可能被系统拒绝操作辅助功能树。
真实 SSH 主题 GUI 回归要求显式提供 `TEST_RUNNER_BAILEY_THEME_TEST_SSH_HOST` 和
`TEST_RUNNER_BAILEY_THEME_TEST_SSH_ROOT`，仅能使用获授权的主机及临时测试目录。
远端测试创建的路径必须先验证完整绝对路径和随机文件名字符集，再用于 Shell 命令或递归清理；
只检查目录前缀不能防止远端输出中的引号或换行变成命令。
系统外观 GUI 回归默认跳过；仅在显式设置 `TEST_RUNNER_BAILEY_THEME_SYSTEM_TEST_ENABLED=1`
并从测试进程外安全切换、恢复 macOS 外观时执行，不在普通测试中修改用户系统外观。
公共启动入口把 `HOME`、`CFFIXED_USER_HOME` 和 Zsh 的 `ZDOTDIR` 都指向测试专属目录，
避免真实终端测试加载用户的交互插件、历史命令或污染个人 Shell 配置。
辅助账户登录且有辅助功能权限仍可能在非 console 会话报 `Can't authenticate off console`；
测试枚举为 0 不表示成功，不能为补测抢占当前桌面。
在 **Bailey Dev 激活后**暂选 ABC，系统选择器的路径输入框获得焦点后再次选 ABC；
测试清理时恢复之前的输入法，并撤销 XCTest 临时启用的 Unicode Hex Input（若该输入法原本未启用）；
此举不替代真实中文 IME 组词／候选测试。真实拼音专项应自动选择系统拼音输入源（TIS），
确认隔离 Dev 与实际编辑控件持有焦点后，通过已有具备键盘事件权限的自动化工具发送字母键及空格候选确认；
发送期间禁止重新激活窗口或直接粘贴 Unicode。断言组合中原字节不变、确认中文、连续撤销／重做及保存字节，
并在退出时恢复原输入源；不要求用户人工输入。AppKit/XCUITest 仍争用同一桌面键盘焦点，
要获得完全无干扰的真实 GUI 自动化须使用独立图形会话。

## 写入失败夹具

真实空间不足回归使用 `BAILEY_WRITE_FAILURE_ROOT`（及 `TEST_RUNNER_BAILEY_WRITE_FAILURE_ROOT`）指向
独立、可耗尽的 512 MiB 以下测试卷；验证正文、旁车、导出与失败后重试。
