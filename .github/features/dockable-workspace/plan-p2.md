# Plan P2 - 原生自由停靠交互与验收

**Goal:** 以 v3 设计稿落地原生布局与拖拽，并完成真机与视觉对照。
**Non-goals:** 不另做第三套文件/Git 树，不重写终端后端。
**Approach:** 用一套 DockWorkspaceView 挂载原有 SidebarView 的内容及 RightSidebarView 的 Info/File/Git 内容、PaneLayoutView；顶部标签样式共享 TabItemChrome。全局 SwiftUI DragGesture 坐标判断边缘单片预览，点击/快捷键保存原有语义。可见区与终端/差异挂载解耦，避免重建会话。
**Acceptance:** 用户提出的三栏自由挪动、合并标签、四向分屏、侧栏隐藏恢复与空位添加、尺寸调整、项目切换/重启均由签名 Debug 真机通过，截图与 v3 对照。
**Rules:** 同一内容同一实例；旧 UI 路径同步清理；不重启仍在运行的任务，不覆盖用户编辑。

---

## P2-T1 统一原生窗口布局和标签交互

**Files:** kero/UI/ContentView.swift, kero/UI/Sidebar/SidebarView.swift, kero/UI/Sidebar/RightSidebarView.swift, kero/UI/WorkspaceDockView.swift

只移动容器与呈现归属，调用现有 FileTreePanel、GitPanel、InfoPanel、PaneLayoutView。保留当前 macOS 顶栏 38pt、轻底色标签、流畅直接拖拽，取消旧的相互独立的侧栏壳与无关状态。

**Validation:** Debug 构建、签名、真实拖拽/开关/重排/编辑/Git/SSH 试用。

## P2-T2 设计对照、回归优化与文档

**Files:** docs/PRODUCT.md, docs/TERMINAL.md, docs/PROJECTS.md, docs/SETTINGS.md, UI issues as found

逐项与 v3 比对：坐标预览、侧栏边界双击复位及普通分隔线均分、键盘/工具条入口、隐藏与空区恢复、重启布局；修正落差并做针对性回归。记录尚无法验证的风险，不宣称假验收。

**Validation:** 旧快照载入、项目切换、签名 Debug 真机截图、git diff --check。
**Commit:** 分逻辑提交。

---

## Phase Audit
- Audit file: audit-p2.md
- 审查原子 commits、UI 行为对照、真实交互及死代码。
