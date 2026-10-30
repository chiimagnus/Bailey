# Audit P5 - interaction-state-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p5.md`
- feature 目录：`.github/features/interaction-state-architecture/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P5-T1 跨领域实际事件链与文件 Git 结果验收
- [x] P5-T2 多主题无障碍极端容量与性能验收

## 任务到文件的映射

- **P5-T1｜真实跨域交互与数据结果**
  - 生产焦点边界：`Bailey/Git/GitPanel.swift`（`009af523`）。
  - 回归：`BaileyUITests/Git/GitChangesUITests.swift`、
    `BaileyUITests/Workspace/WorkspaceDockUITests.swift`、
    `BaileyUITests/Files/WorkspaceFilesUITests.swift`、
    `BaileyUITests/Workspace/WorkspaceRetentionUITests.swift`、
    `BaileyUITests/Support/WorkspaceUITestSupport.swift`。
  - 当前契约：`docs/architecture.md`、
    `docs/features/command-palette.md`、`docs/features/dock.md`。
  - 核心提交：`4615eb6c`、`f8ab3e68`、`009af523`、
    `f316af8b`、`4cfb09b8`、`e22c901e`。
- **P5-T2｜外观、AX、规模与性能**
  - 回归：`BaileyTests/Files/FileTreeTests.swift`、
    `BaileyUITests/Git/GitGraphGeometryUITests.swift`、
    `BaileyUITests/Git/GitGraphUITests.swift`、
    `BaileyTests/Workspace/ProjectFileIndexTests.swift`。
  - 当前规范：`docs/testing.md`、`docs/ui.md`、
    `source-review.md`、`evidence-p5.md`。
  - 核心提交：`3ad9085e`、`be3da639`、`e42e6fe0`、
    `edc31129`、`feed7e5d`、`a1e26c70`。

## 发现项

## 发现 F-01

- 任务：`P5-T1`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`BaileyUITests/Workspace/WorkspaceRetentionUITests.swift:37-55`
- 摘要：`Xcode 测试器重启隔离 App 后未创建默认窗口时，补开主窗口后的 Cmd-, 偶发不显示 Settings`
- 风险：`特定合成无窗口场景下的 Settings 键盘入口尚不能保证；未在正常用户启动重现，不能冒称生产修复或完整快捷键验收`
- 预期修复：`在无损坏用户配置的真实 Dev 场景中隔离复现并记录 keyWindow、当前第一响应者及原生主菜单；只有证明生产可达且失效后才在 Settings/窗口实际 owner 修复`
- 验证：`隔离 GUI 首次 Cmd-, 已通过；重启后原生 Settings 菜单恢复及 TOML/深色 Tab/关闭设置窗口 2/2 连续通过；必要补验无初始 WindowGroup 的 Cmd-, 用户路径`
- 解决证据：`原生 Cmd-, 在首次启动已通过；合成重启时若默认 WindowGroup 不呈现，手动 New Window 后 Cmd-, 的失败日志 /tmp/bailey-p5-relaunch-focus-combined-20261031.log。真实系统 Settings 菜单 + App 终止/重启 + TOML 和 Dark Tab + Cmd-W 通过（/tmp/bailey-p5-settings-native-menu-combined-20261031.log），未找到普通用户路径的生产重现；本范围不加全局键盘监听/窗口恢复补丁。`


本轮发现项由 `feature_tool.py finding` 写入。除 F-01 外，
已发现的四项可执行 GUI 失败均完成 Red→Green，
未发现新的可达生产数据边界缺失；不把设备未覆盖自动升级成假想代码缺陷。

## 修复日志

- `009af523`：原生 Git 树注册焦点时验证 Command Palette 可见性、
  当前窗口和原生 Sheet，避免焦点抢占；复核后生产变更只有
  `GitPanel.swift` 的最小 guard，无新增 FocusManager／全局键盘监听／旧双轨。
- `f316af8b`：测试启动等待原生 WindowGroup，避免初始窗口稍晚出现时
  与测试兜底新建窗口重叠；Finder→WKWebView 拖放改为真正未被遮挡的点。
- `4cfb09b8`：在同名本机／Windows SSH `drop-zone` 夹具中先明确选中
  Windows 项目，再断言实际展开、远端路径和拒绝上传；
  同一个 Finder 文件必须成功复制到本机作为正向控制。
- `a1e26c70`／`e22c901e`：按系统使用真实 Tab／RadioButton；
  Xcode 合成无初始窗口的重启后走原生 Settings 菜单验证主题持久化。
  **没有修改生产 Settings**；F-01 对该合成条件下 `⌘,` 保留 Deferred。
- 所有修改只在现有生产 owner 或已有测试入口；未新增兼容层、
  全局焦点管理器、额外窗口恢复器、临时重试计时器或新依赖。

## 验证日志

- **宿主全集**：`BAILEY_P4_TEST_SSH_HOST=windows ... make test`，
  `723/723`、0 失败、0 跳过、退出码 0，日志
  `/tmp/bailey-p5-palette-host-full-20261030.log`。
  相同生产焦点版本 `009af523` 后未再修改生产代码。
- **真实 Dev GUI**：按互斥测试类分三组覆盖全部 **190 个不同方法**：
  A 组 59/59 绿；B 组 77/78，唯一周期重复标题位图夹具经
  `edc31129` 修正后同用例 1/1 绿；C 组 49/53，四条真实红灯
  逐条定位，命令面板／SSH Finder／WebKit 拖放均专项绿，
  且在含五方法的实际连续 UI 组中再次绿。
  重启设置页原生菜单与 WebKit 在最后两方法连续组 **2/2** 绿。
  完整证据：`evidence-p5.md` 及 `/tmp/bailey-p5-*20261031.log`。
  五方法联合组原本 4/5，唯一缺口为合成无初始窗口后 `⌘,`，
  **不能把这份失败日志称为全绿，也没有同一命令 190/190 的报告**。
- **数据与窗口反例**：Windows SSH 的同名目录／同名本机文件、
  Finder 真实 fileURL、远端不可写回本机、保留 Git HEAD／index／refs、
  双 NSWindow 和 Dev 专属 SSH master 断开重连、脏文件退出保护、
  Shell／WebKit／Editor 身份保留均有相应宿主与 GUI 实际结果。
  Git Graph 40 个离屏历史文件导航逐行核对可见性、HEAD、文件字节；
  Dock 30 次真实切换完成、无错误目标，自动化中位约 3.378s
  （包括 XCTest／AX 等待，不能宣称纯 App 响应时间）。
- **极端规模与外观**：真实 1k／10k／100k 本机 APFS 文件目录及
  NSHostingView／NSScrollView，原生底部滚动和内容高度断言，
  高对比 Aqua／DarkAqua 行位图；新增宿主 2/2 绿。
  100k 的加载 6.581s、原生挂载 0.154s、滚动 0.921s，
  测试进程峰值 RSS 338.9 MiB；不是单独的 App 内存。
  另有 100k TextKit、千级 Git、32 Dock 项的宿主边界证据。
- **构建签名**：最终 `make build:dev` **0，BUILD SUCCEEDED**；
  `codesign --verify --deep --strict --verbose=2` **0，签名有效**；
  `feature_tool.py todo validate` 和 `phase-complete --phase p5` **通过**；
  `git diff --check` **通过**。未改变正式 Bailey 安装与进程。
- **环境缺口／潜在影响／补验**：
  - **macOS 15.6 最低支持版本**：本机只有 27.2，旧系统的
    SwiftUI segmented Picker、AX／窗口行为未真机验证；
    在 15.6 独立 Dev／CI 机执行宿主与关键 GUI，**不得据此发布全版本通过声明**。
  - **实体 VoiceOver／中日文 IME／第二显示器／触控板中键**：
    当前不能在不影响用户正在使用的桌面与输入设置的情况下安全完成；
    AX/高对比宿主与编辑器标记文本仅是替代证据；
    在获准的独立桌面与对应硬件补测导航朗读、组词提交和跨屏拖放。
  - **长时 Instruments 帧间隔和内存回落**：本轮为短时规模／响应基线，
    无法排除长期资源增长；独立设备以 100k Files、30+ Dock
    标签重复切换进行 Time Profiler／Allocations 连续观察。
  - **Windows 整机网络隔断／两个 Dock 组叠加断线**：
    已验证 Dev 专属 SSH master 断开与真实双窗后恢复，
    未擅自切断用户共用网络；需受控的独立 Windows/网络试验。
  - **F-01（Deferred）**：仅 Xcode 无默认窗口的合成重启后 `⌘,`
    尚无可信生产用户路径复现；见 finding，不能称此入口已通过。
- **文档与许可**：复核 `docs/ui.md`、`docs/architecture.md`、
  `docs/features/{files,git,dock,projects,command-palette}.md` 与
  `docs/testing.md` 当前 owner、界面语义及计划链接。
  上游 VS Code／Git Graph 仅对照状态与行为，
  本阶段未复制扩展 CSS／实现或引入许可证限制内容。
  `SettingsView` 等生产设置代码未因 P5 被更改。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（**仅本机 macOS 27.2 的 Dev 实施与可执行验收范围**）。
- 理由：本机可安全执行的 P5 行为、数据、外观、容量和构建签名
  均有可追踪实测证据；F-01 及设备级缺口明确 Deferred，
  **不构成 macOS 15.6／辅助功能／长期性能已认证，也不批准全平台发布**。

## 最终状态与剩余风险

- 当前状态：`Resolved`（本机阶段审计）；`F-01` 仍为 `Deferred`。
- 剩余风险：最低系统真机、实体 VoiceOver／IME／跨屏、长期资源，
  以及特殊 XCTest 无初始窗口下的 `⌘,`；
  实际用户覆盖前按上述条件补测，不把本机 Go 解释成完整发布验收。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
