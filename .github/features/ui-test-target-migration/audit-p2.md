# Audit P2 - ui-test-target-migration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/ui-test-target-migration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 编辑导航、原生输入、IME 和撤销
- [x] P2-T2 文件标签、真实读写、保存冲突与断线恢复
- [x] P2-T3 语法高亮、主题、组合字符与原生颜色
- [x] P2-T4 Diff 原生绘制、编辑、展开及真实保存

## 任务到文件的映射

- **P2-T1（旧 38 项）**：`BaileyTests/Integration/Editor/NativeEditorLayoutTests.swift` 28 项、`NativeEditorCompositionTests.swift` 10 项；`TextCoordinateIndexTests.swift` 9 项补充坐标回归；`BaileyUITests/Editor/EditorNavigationUITests.swift` 3 项验证独立 App 的实际输入与字节。
- **P2-T2（旧 49 项）**：`BaileyTests/Integration/Files/FileTabPersistenceTests.swift` 33+16 项；`BaileyUITests/Files/WorkspaceFilesUITests.swift` 9 项及 `BaileyUITests/Support/WorkspaceUITestSupport.swift` 验证文件树、原生选择器、焦点、同名路径和最终保存。
- **P2-T3（旧 22 项）**：`BaileyTests/Integration/Editor/NativeSyntaxHighlightingTests.swift` 22 项及 `BaileyUITests/Editor/EditorHighlightingUITests.swift` 真实 Swift/纯文本截图颜色与原字节。
- **P2-T4（旧 35 项）**：`BaileyTests/Integration/Git/NativeDiffTabTests.swift` 35 项、`BaileyTests/Unit/Git/DiffEngineTests.swift` 6 项辅助算法测试；`BaileyUITests/Git/WorkspaceGitUITests.swift` 验证真实 Git Changes、Git Graph 和 Split／Unified／Edit／Undo／Redo／⌘S。
- **共享测试入口**：`BaileyUITests/Support/WorkspaceUITestSupport.swift` 按真实 AX 语义输入，启动前暂选 ABC、清理时恢复原拼音；`Bailey/Git/DiffViewerView.swift` 的 AX ID 不改变产品视觉；`docs/testing.md`、`docs/development.md`、`docs/features/editor.md`、`docs/features/diff.md` 已同步。

## 发现项

截至本次审查，P2 本机复核中**没有未修复的、已证实的产品代码回归**。实施期发现的输入法复原／AX 类型／本地化搜索／原生 Diff 颜色采样／测试偏好污染均已由 `2c7b51b` 根因修正，并有完整运行证据。原先 Git 测试点击宽度为零的隐藏 AX 标签，改用真实 ⇧⌘G 用户入口，三项全部实测通过。

本阶段剩余的未验证条件列于验证日志，不以未经验证的 CI、SSH 或实体设备结果推定通过。

## 修复日志

- `b094047`、`5bc6fe2`、`7e27b61`、`6b65c00` 保留 P2 四任务所有旧方法与必要原生契约，按源码去向迁移；非目标旧路径已从 Git 索引消失。
- `2c7b51b`：Apple Development 签名 GUI 测试；测试入口在启动 Dev 前选择 ABC、每条用例退出恢复拼音并取消 XCTest 暂时启用的 Unicode Hex Input；中文与英文命令面板走对应本地化文本；Git 通过实际快捷键而非隐藏元素；AppKit 控件按真实 `RadioGroup` AX 类型查询。
- 同一提交：Diff 位图转 sRGB 通道读取，保留现有容差和红绿／删除 ghost 断言；使用每例独立 UserDefaults 解决持久化 Edit 模式阻止正常重载的超时，不删除生产保护；新增真实 Split→Unified 双区域和 Edit／Undo／Redo／保存字节断言。
- 本阶段没有改动或重启正式 `/Applications/Bailey.app`，也没有更改授权范围外的仓库或用户文件。

## 验证日志

- **环境**：2026-10-23，macOS 27.2（26B5101f）、arm64，Xcode 27.2（27B5038j），独立 `chiimagnus.bailey.dev`，个人 Apple Development 签名。`codesign --verify --deep --strict` 对 Bailey Dev 和 UI Runner 都通过；Runner Team ID 为本机开发身份；正式 Bailey 进程 `21030` 保持存活。
- **原方法覆盖**：从当前受测 Swift 源文件重新扫描：P2-T1 28+10、T2 49、T3 22、T4 35，**144/144**；对应旧 NativeUI 源文件已不存在。独立 `BaileyUITests` 源码 20 个方法，且未导入 Bailey 产品模型；`migration-inventory.md` 保留逐方法映射。
- **宿主**：`make test:FileTabPersistenceTests,NativeFileTabTests,NativeSyntaxHighlightingTests,NativeDiffTabTests DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，106/106，0 failures，exit 0**（`/tmp/bailey-p2-host-106-final.log`）。覆盖保存事务／失败保留、原生视图、Tree-sitter 高亮/异步、Diff 行/像素/异步折叠/撤销。没有删除原始 35 个 Diff 契约断言。
- **底层补测**：`make test:NativeEditorLayoutTests,NativeEditorCompositionTests,TextCoordinateIndexTests,DiffEngineTests DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，53/53，0 failures，exit 0**（`/tmp/bailey-p2-editor-core-final.log`）。包含输入法组合的 AppKit 契约、十万行坐标和 Diff 算法，不冒充实体拼音选字。
- **完整 App E2E**：`make test:ui DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，20/20，0 failures，exit 0**（`/tmp/bailey-p2-ui-full-20-final.log`）。通过 Swift／纯文本截图颜色比较、十万行首尾输入和精确保存、中文长路径系统选择器、同名不同路径文件、键盘焦点和中英文 Palette、Git Changes／Graph、真实 Diff Edit／Undo／Redo／⌘S、双窗口及设置。
- **增强 Split E2E**：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests/testWorktreeDiffEditsAndPersistsRealGitFile DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，1/1，exit 0**（`/tmp/bailey-p2-diff-split-exit-edit.log`）。先切 Review，实际点 Split 并核对两个原生文本区域，再 Unified、Edit、Undo／Redo 和最终 UTF-8 文件字节；支持从用户保存的 Edit 模式开始。
- **系统输入复核**：每次正常 GUI 用例后恢复系统拼音；整套 20/20 结束后读取 macOS 已启用输入法：ABC、拼音保留，`Unicode Hex Input` **不在列表**。未对 `/Applications/Bailey.app` 进行启动、退出、替换或重签名。
- **未测／条件性边界**：① **macOS 15.6 真机**不可用；可用27.2和原生 contract 为替代，但不能证明最低系统版本 GUI 兼容，需该系统 Runner 复测，发布全平台 Gate 阻塞。② **GitHub CI ad-hoc UI Runner**尚无此提交的远端 Job；本机强制 ad-hoc 曾遭系统拒绝 UI 权限，本机开发签名成功不代表 CI 成功；需提交/推送授权后查看 GitHub Actions 真实结果，CI Gate 阻塞。③ **真实 Windows SSH 断线／重连／多机器归属 GUI**未执行；受控后端保存、旧结果失效测试已通过，仍不能取代经授权远端 E2E，相关远端 Gate 阻塞。④ **实体拼音候选、其他物理触控板与外接显示设备**未验；ABC 路径和 AppKit 组合输入契约通过，但不能声明真实候选/设备组合通过；按设备可用性补测。⑤ GUI 未单独遍历 Markdown／TSX／HTML/CSS 的全部主题、字体、最窄窗口和动态外观组合；已有 22 条原生语法高亮测试及 Diff 明／暗像素合约通过，完整视觉矩阵仍须补验。以上条件不推断为产品 bug，也不纳入本次代码提交。
- **文档/命令**：`AGENTS.md` 保护正式 App 的约束、`docs/testing.md` 与 Makefile 的 `test:ui` 目标、`docs/development.md` 本机签名指导、`docs/features/editor.md` 和 `docs/features/diff.md` 已核对；相关路径、类名、测试结果与源码一致。`git diff --check`、`todo validate` 均通过，Feature 状态和审计文件按 Skill 默认保留本地，不提交。

## Gate（是否允许进入下一阶段）

- 结论：**No-Go（完整跨环境验收）；本机 P2 实施与可执行回归全部通过，可以开展不依赖缺位环境的 P3 任务。**
- 理由：P2 旧方法 144/144 均有新归属，159 条宿主及 20 条完整 App GUI 全通过；但 CI ad-hoc、最低 macOS 15.6、真实 SSH 和实体 IME 等用户明确要求保留的条件仍缺实际 Runner 证据，不能将本机绿色称为所有环境验收完成。

## 最终状态与剩余风险

- 当前状态：**Open（外部环境补验待完成；P2 四任务本机实现均为 completed）**
- 剩余风险：待获得 CI Runner、macOS 15.6 和经许可的 Windows SSH／实体输入设备后逐项补验。最终全项目分离目标仍含 P3／P4／P5，当前 P2 不冒称所有旧 UI 宿主测试均已删除。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

