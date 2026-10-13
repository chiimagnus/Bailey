# Audit P6 - swiftui-observation-mvvm-refactor

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p6.md`
- feature 目录：`.github/features/swiftui-observation-mvvm-refactor/`
- 粒度：`phase`

## 任务看板

- [x] P6-T1 将跨面板根目录解析与刷新编排移出 SwiftUI View
- [x] P6-T2 将命令面板文件索引迁出 View 并保留即时交互状态

## 任务到文件的映射

- P6-T1：`52012db`；`kero/Git/GitStatusModel.swift::syncSelectedProject`、`kero/Workspace/Project.swift::syncFiles`、`kero/UI/ContentView.swift`、`kero/UI/Panels/ToolPanelView.swift`、`KeroTests/PanelContextTests.swift`。
- P6-T2：`870f86d`；`kero/Workspace/ProjectFileIndex.swift`、`kero/UI/CommandPaletteView.swift`、`KeroTests/ProjectFileIndexTests.swift`。

## 发现项

- 本阶段审查未发现仍开放的、符合 finding 门槛的正确性问题。实际发现并已随 `870f86d` 修复：普通目录通过 Foundation URL 枚举时 `/private/var` 与 `/var` 字符串前缀不一致，搜索结果错误地全部被丢弃；改用目录相对路径遍历并在回归测试覆盖。
- 检查业务路径：`ContentView` 只触发 `GitStatusModel.syncSelectedProject`，后者先核对窗口选中 Project、上下文身份和请求代次，再调用既有 `GitStatusModel.sync`，其代次保护维持；`ToolPanelView` 只触发 `Project.syncFiles`，既有 `PanelSyncQueue` 合并及 2 秒活动 Files 刷新未移除；项目和机器变更后旧结果不进入可见状态。
- 命令面板 `.task` 仍以上下文身份取消旧索引，helper 仅通过现有 Git 执行器/本机 FileManager 读取，不接入远端路径，不复制缓存；`@State` 保留查询/选择/指针临时输入，删除无用途 `ObservableObject` 和 View 内旧索引方法。

## 修复日志

- `52012db`：移走两处 View 后端解析/同步路径并使用当前状态 owner，受控双目录选择回归。
- `870f86d`：移走命令面板索引，并修复实际可复现的 `/var` 路径别名问题；保留原始路径用于真正打开。

## 验证日志

- `make test ONLY_TESTING=KeroTests/PanelContextTests` → PASS（3/3）；`WorkspaceIdentityTests` → PASS（4/4）；`GitStatusModelTests` → PASS（4/4）。
- `make test ONLY_TESTING=KeroTests/ProjectFileIndexTests` → PASS（2/2：Git 跟踪/非忽略/Unicode+换行文件名、非 Git 目录 `.git` 排除及取消）。
- `make test`（`/tmp/kero-p6-full-tests.log`）→ PASS（71/71）；`make build`（`/tmp/kero-p6-final-build.log`）→ PASS；`codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app` → PASS。
- 隔离 Debug PID12414：临时 Git 仓库添加后 Files 定时可见新文件、App 重获焦点后 Git 显示实际 Untracked；PID15631：⌘P 搜索 `sample.txt` 并点击后真实文件标签出现；65 个匹配文件最高展示 50 项、键盘循环/两次 Esc 符合旧交互。正式 `/Applications/Kero.app` 未修改、退出或重启；未使用真实 SSH 用户连接。
- `rtk codegraph explore` 核对索引/helper 与 Window 项目的真实调用链；旧 `CommandPaletteView` 内 `loadProjectFiles`、`gitProjectFilePaths`、`enumeratedProjectFiles` 实现已删除；`git diff --check` 通过。

## Gate（是否允许进入下一阶段）

- 结论：**Go**
- 理由：P6 两项实现均由产品入口真实调用，旧 View IO 路径已删除，跨项目与本机索引的正常/失败边界均有受控测试和隔离 UI 真实结果，全量构建及测试通过。

## 最终状态与剩余风险

- 当前状态：**Resolved**（本阶段无 Open finding）。
- 剩余风险：真实 SSH 远端不可在不使用用户连接的情况下做端到端验证，限于受控 WorkspaceBackend 与现存 SSH 隔离测试；命令面板产品约定为仅索引本机目录，未扩展远端。P7 的真实 Swift 6 编译与 Release 验收尚未执行，不属于 P6 通过依据。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

