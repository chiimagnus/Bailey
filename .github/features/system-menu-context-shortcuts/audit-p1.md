# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go（调查门禁；不是修复或发布验收）。
- **依据**：右键期间原生系统命令多能正确执行，但首次分发和常态分发的视觉反馈不同；
  现有 `⌘W` 原事件重投是有效阳性对照。不得用局部按键监听接管所有应用命令。

## 任务与改动

- **P1-T1 真实事件与像素**：`BaileyCommands` 注册实际系统命令；`BaileyApplicationDelegate`
  临时记录 NSMenu 开始、结束和发送动作，本地日志保留事件时间戳、菜单及第一响应者类型。
  `ContextMenuClickView`／`FileTreePanel.handleMenuKeyDown` 是 Files 普通 Edit 的原有局部路径。
- **P1-T2 目标和实际副作用**：`9861d5e9` 扩充 `GitChangesUITests.swift` 的真实
  Stage All、Commit Staged、Diff Layout，确认剪贴板以外的效果到达 Git index、HEAD
  与原生 Diff 文本，而非只确认事件到达。旧关闭功能的合并状态另见 `9a17fe2a`。

## 实验结果

| 展开的菜单／按键 | 实际路径、目标及结果 | 第一次反馈 |
| --- | --- | --- |
| Dock 后台 Files、文件及组选区／⌘W | 同一时间戳先选中系统 Panel 命令，不关闭；原事件重投后选中一次并关闭。本次关闭正确，后续普通 ⌘W 回到活动组。Control-Click、取消、多选及双窗用例另测。 | Panel 真正高亮；普通第二次也高亮。 |
| Files 目录／⌘N、⌥⌘N | popup end 和系统 File 动作使用同一 keyDown 时间戳；文件和目录只在真实右键目录创建。 | 未见 File 闪亮。 |
| Files 文件／⌥⌘C | popup end 后系统 File Copy Path，输出右键文件；再次 ⌥⇧⌘C 回到原选区。 | 右键首按无闪亮，普通对照有 File 闪亮。 |
| Files 文件／⌘C | popup 自身 Copy 动作，而非 Edit Copy；保留 Files 选区或 Terminal 第一响应者，验证了传输剪贴板类型及真实 Shell 写入。 | 未见 Edit 闪亮。 |
| Git Changes／Graph 路径 | 系统 File 动作；右键目标、压缩目录与组内多选写入正确内容，不改文件或迁移选区。下一次普通命令恢复原选区。 | 未观察到与普通 File 命令相同的首按闪亮。 |
| Git 暂存与提交／⇧⌘Y、⌘↩ | 当前 Git 仓库全量暂存；提交采用实时编辑框文案、只写暂存的字节。未改变原有第一响应者。 | File 动作到达不等于有反馈；录屏中 Stage All 与 Commit 时点没有常态闪亮。 |
| Git 行／⌥⌘U | 仍切换活动只读 Diff；校验切换后的两侧真实 TextKit 内容与系统鼠标点击。 | 事件证据来自修正夹具后的实测；该次录屏未启动。 |
| Files 或 Dock 后台菜单／⌘P、⌘T、⇧⌘N、⌘S | Panel palette 出现；Terminal 接收命令并实际写标记；Window 多了一个；编辑中的两个同名文件各自保存到原路径。 | Panel、Terminal、Window、Edit 的右键按键没有相应常态闪亮；⌘P 无 popup 对照有。 |
| Projects／⌘2；Files／⌘L | 分别命中第二项目、活动 Browser 的原生地址栏；内容未修改。 | 项目右键首按没有 Project 闪亮；Browser 普通 ⌘L 有闪亮，右键首按没有。 |

Git Graph 上历史文件不支持 Finder 定位：系统 Reveal 项禁用，快捷键可经过 local monitor，
但**没有**结束菜单或调用命令。一次失败的后续 Copy 探针误把 AX 菜单查询不到当成
popup 已关闭；日志证明真正结束的是后续有效 Copy 的事件，不能把该用例算作旧目标泄漏。
Files 禁用 Paste 探针也不能用全局菜单项 `isHittable` 判断上下文菜单，
用仅存在于 popup 的动作确认实际跟踪，再明确退出。

普通 SwiftUI 系统项在 popup 的 keyDown 导致菜单终止后紧接着分发，
而测试局部 monitor 看不到这一按键。Files 的 Copy 和禁用命令在 monitor 中出现，
与 [AppKit 本地监视器契约](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))
一致。P2 应沿实际系统项的入口复用重投，不在应用内基于字符匹配复制系统快捷键。

## 发现项

任务提交仅改变 XCTest；实际被调用的是 App 中原来的原生菜单和业务路径，没有替换
事件派发，也没有新增生产快捷键。阶段没有需要修复的实现 finding。
反馈和短暂目标的风险交给 P2，不将禁用命令保持未关闭的同一次菜单认作目标泄漏。

## 验证与未覆盖

- macOS 27.3 (26C5035r) arm64，Xcode 27.2 (27B5038j)。正式 Bailey 保持运行且未被触碰；
  用户让出控制台，`make test:ui ONLY_TESTING=…` 使用开发签名、临时 HOME 和项目夹具。
  `make build:ui` 退出 0，Dev 与 Runner 均经 `codesign --verify --deep --strict`，
  Dev Bundle ID 核对为 `chiimagnus.bailey.dev`。
- `build/context-shortcuts-p1-baseline-ui.log`：退出 0，7/7；
  同名前缀 MP4 只记录菜单栏。Panel 高亮分别见视频 131.633–131.750 s、133.050–133.167 s。
  Files 的普通路径高亮在 143.167 s、143.300 s，右键第一次 Copy Path 无对应脉冲，
  后续普通 Copy Relative Path 在 145.383 s 高亮。普通路径、菜单截图和实际操作均有日志。
- `build/context-shortcuts-p1-event-probes.log`：9 项，整体退出 2。
  初版探针的系统菜单查询、Diff 选中等待和中文 Close 标题有夹具问题，不算功能回归。
  `build/context-shortcuts-p1-eligibility.log` 复测其中 Commit、Diff、Save 通过；
  三轮的同名 `.events.log` 保留实际 AppKit 跟踪和动作时间戳。
- `build/context-shortcuts-p1-targets.log`：6 项，整体退出 2；Dock 取消、Control-Click、
  选区单次关闭、实际双窗隔离四项通过；两个否定用例先修正菜单跟踪断言再判断。
- `build/context-shortcuts-p1-final-probes.log`：4 项，整体退出 2；Project、Browser 通过，
  同名 MP4 中普通 Browser 焦点按键在 102.083 s 高亮；popup 的第二次 Browser 及 Project 按键
  没有系统菜单栏脉冲。Files 的未启用 Paste 未发送剪贴板，正常 Terminal 命令仍写入字节，
  但 AX 的 Rename 可见性断言失败。两项误判未纳入回归提交。
- macOS 15.6 没有可用主机；不能把当前 SDK 的 API 可用性推断为旧版菜单时序。
  没有授权 SSH 主机与路径，未连接实际远端；本机测试与既有身份/后端回归不代替远端 GUI。
  当前 XCTest 选用 ABC，并没有覆盖正在组词的中文 IME；需另用受控输入法验证。
  上述差异不改变这台机器上已证明的原生分发边界，但不能据此放行 P2 的最终验收。
- 宿主 `AppIdentityTests` 19/19、`DockWorkspaceTests` 38/38、`FileTreeTests` 100/100。
  `build/context-shortcuts-p1-host.log` 合计 258/258，退出 0，Dev 与宿主测试包验签通过。
  `git diff --check` 通过；临时事件观察器已移除，当前功能文档未宣称新行为。
