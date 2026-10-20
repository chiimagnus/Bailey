# Focus：统一窗口、停靠区域、内容与文件树焦点

需求归属：[Issue #13](https://github.com/chiimagnus/Bailey/issues/13)。File Manager 多选与拖放属于 [Issue #5](https://github.com/chiimagnus/Bailey/issues/5)；本计划先提供可靠的焦点归属与视觉基础，不提前实现其文件操作。快捷键自定义属于 [#43](https://github.com/chiimagnus/Bailey/issues/43)。

## 已核对的事实

- `WindowRootView` 为每个主窗口建立独立 `TerminalManager`，`BaileyApp.BaileyCommands` 通过 `focusedSceneValue(\.baileyManager)` 选择窗口；`NSWindow.didResignKeyNotification` 已触发编辑自动保存。
- `DockWorkspaceModel` 只有 `root`；每个 `DockGroup.selected` 表示该组展示的标签，**没有**独立的活动组。全局 `Project.selectedTabID` 只适用于编辑／终端／浏览器／Diff 标签，不代表 Projects、Files、Git 的真实焦点。
- `WorkspaceDockView.DockTabGroupView.select` 只改组 selected，工作标签的 `PanelContentView.onFocused` 只更新 `selectedTabID`。工具面板没有同等聚焦回调；Ghostty、TextKit、WebKit 已有各自原生焦点桥，不能用选中标签替代 `NSWindow.firstResponder`。
- 共享 `TreeRowSurface` 已有 `selected` 与 `focused` 外观；Files 当前仅在新建／重命名 `TextField` 用 `@FocusState`，行高亮仍来自当前编辑文件路径。文件树多选、选择锚点及行级键盘交互由 #5 P1-T1 实现。
- `DockWorkspaceConfiguration` 仅控制新项目初始布局，`SessionStore` 已保存每个项目的 Dock 树；**原生 first responder 和短暂活动组不应伪装成可恢复的持久焦点**。

## 目标

1. **窗口焦点。** 系统 key window、App active 是唯一真实前台判断；后台窗口可记住自己的上次目标，但不能显示活动边框或抢输入。
2. **区域焦点。** 每个处于前台的主窗口最多一个活动 `DockGroup`。它独立于每组的 `DockGroup.selected`；工具面板、编辑器及空组地位相同。
3. **内容焦点。** 点击标签、标题／空白、Projects／Files／Git、终端 Ghostty、编辑 TextKit、浏览器 WebKit、Diff 后，活动区域随真实输入接收者切换；`NSWindow.firstResponder` 仍是键盘输入归属的最终证据。弹窗、菜单或重命名输入激活后不凭旧 tab ID 派发写入。
4. **视觉。** 聚焦区域有克制且可辨认的整体强调；未聚焦组保留各自 selected 标签，不能冒充真正焦点；Files 的多选行、行键盘焦点、当前打开文件高亮各自表达，焦点相关的共享行视觉由 #13 提供，具体选中状态由 #5 提供。
5. **转移与恢复。** 拖放合并/拆分、切标签／项目、增删区域、切换窗口与 App、恢复快照后焦点总指向仍有效的区域，不能用悬停/拖放预览冒充焦点。文件失焦自动保存、Ghostty 前后台焦点和 WebKit 输入不得倒退。
6. **操作归属。** 保留 `BaileyCommands` 已有 focused window 路由；菜单、键盘操作只指向当前真正有焦点的内容。#5 中 `⌘A/C/X/V` 仅由获得键盘焦点的 Files 树处理，不能抢走编辑器／终端的标准快捷键。

## 边界与顺序

- 本计划先形成跨区域 Focus 的真源，再让 #5 P1-T1 使用它实现文件行选中；**不在 #13 增加文件选择集合／剪贴板／拖放数据传输**。
- 优先在现有 `DockWorkspaceModel`、`WorkspaceDockView`、`TerminalManager` 及原生视图回调中解决，不造全局 `FocusManager`、第二套 Dock 树、轮询或额外通知总线。
- 不新增用户可自定义焦点边框参数；原设计稿中的强调强度／演示快捷键仅用于探索，不是产品设置。正式自定义快捷键归 #43。
- 不修改 Settings 分区或 Exclude 行为；Settings 归 [#44](https://github.com/chiimagnus/Bailey/issues/44)，Files 选择归 #5。跨功能真实验收要在各功能实现时再次进行。

## 尽可能完整的验收范围

- 单组、水平／垂直、六组以上嵌套、空组、目录/工具面板/编辑/浏览器/Diff、同时打开多种原生内容；每组保留各自 selected，而全窗口只有一个活动组。
- 本机多主窗口、前台/后台、Settings/Sheet/菜单/弹出框、不同项目 A→B→A；标签重排/移动/拆分/关闭/恢复/删除活动组后无悬空焦点，旧窗口不能执行命令。
- 真正键盘输入、剪贴板、快捷键、↑↓、⌘P、⌘F、⌘S、文件重命名、失焦保存、终端/编辑器/浏览器 first responder，不能只检测回调；Tools 不被旧终端抢回焦点。
- 本机／授权 SSH、macOS 15.6+／当前机器、中英、明暗、窄宽及大型字号、VoiceOver 和键盘导航；每个可执行场景、异常和极端组合最大化实测，缺失设备明确说明影响与补验。
- 不重新创建原生文本视图、Ghostty Surface、WebView、Diff；持续占用、FPS/刷新、内存与窗口生命周期无回归。验证见 [docs/testing.md](../../../docs/testing.md)。

维护文档：`docs/features/dock.md`、`docs/ui.md`、`docs/features/editor.md` 以及实际受影响的 terminal/browser/files/command-palette 文档。修改时按对应任务更新，不提前宣称已实现。
