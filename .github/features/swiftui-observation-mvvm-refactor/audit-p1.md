# Audit P1 - swiftui-observation-mvvm-refactor

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/swiftui-observation-mvvm-refactor/`
- 粒度：`phase`

## 任务看板

- [x] P1-T1 核对迁移基线并取得 Swift 6 诊断
- [x] P1-T2 将窗口自动保存改为语义变更触发

## 任务到文件的映射

- P1-T1：`kero/App/keroApp.swift`、`kero/Workspace/{TerminalManager,Project,PaneTab,SessionStore}.swift`、`kero/Terminal/TerminalHistory.swift`、`kero.xcodeproj/project.pbxproj`、`Makefile`、`KeroTests/*.swift`。证据：本机忽略目录 `evidence/p1-baseline/README.md`，包含正式 Kero 原生窗口截图、受控隔离 Debug 基线、构建测试日志及 Swift 6 诊断。
- P1-T2（Commit `259ac58`）：`kero/Workspace/{TerminalManager,Project,DockWorkspaceModel,PaneTab}.swift`、`kero/Terminal/TerminalSession.swift`、`kero/Browser/BrowserView.swift`、`kero/Editor/FileViewerView.swift`、`kero/Git/DiffViewerView.swift`、`KeroTests/SessionStoreTests.swift`、`docs/SETTINGS.md`、`plan-p1.md`。

## 发现项

## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`KeroTests/references/check-app-identity.swift`
- 摘要：`两个历史测试参考文件仍要求已移除的 Kero Dev 包名及独立数据目录`
- 风险：`失效脚本虽被排除构建，却会误导以后审查者恢复已明确放弃的多 App 身份`
- 预期修复：`删除无当前消费者的两个过时历史身份脚本，同步 Xcode 排除清单；保留真实使用的一套 Kero 身份及现行 AppIdentityTests`
- 验证：`rg Kero Dev kero-dev; make test ONLY_TESTING=KeroTests/AppIdentityTests; make build`
- 解决证据：`已删除两份过时多 App 身份测试并同步 Xcode excluded sources；当前 AppIdentityTests 2/2，全套 XCTest 89/89；Debug、Release 严格签名通过，当前只有 chiimagnus.kero。`


无符合 finding 门槛的未修复 P1 正确性问题。逐字段核对 Snapshot 与各 Owner 的 setter 后，`autosaveObservation` 已消失，唯一业务写入路径仍为原 `saveAll → SessionStore/TerminalHistoryStore`。

**计划验收修正（证据与范围一致）**：旧 P1-T2 文字要求在本任务模拟系统级终端历史开关及真实回放，但变更范围只是保存触发事件来源，且隔离 App 仍与正式 App 共用全局配置。直接切换 `AppSettings.shared.restoreTerminalHistory` 会写真实 `config.toml`，违反安全验收。P1 采用实际存储层的历史键/sidecar 联动检查与代码调用链审查，不把它称作滚动历史重启测试；真实回放属于 P5/P7 原生生命周期完整验收。

**未开展的 UI 场景**：P1 已保留同场景正式/隔离截图及项目、文件树、终端和加号菜单参考；设置、浏览器、Diff、快捷键和模态框须在 P2～P6 相应 View 改造之前额外采基线和实操；不能因为 P1 快照而假定这些页面零变化。

## 修复日志

- P1 完成提交 `259ac58`：逐个状态 Owner 添加弱引用的语义变更通知和 500ms 取消合并；立即删除旧 autosave Publisher；保留尚在使用的 SwiftUI 发布器直到所属迁移 Task。
- 审计未修改生产代码；仅把 P1-T2 不适合在共享正式配置下进行的终端历史回放验收明确归入后续受控生命周期核验。

## 验证日志

- `make doctor` -> PASS，Xcode 27.0 / macOS 27.2 / Swift 6.4。
- `make test`（改动前） -> PASS，33/33。
- `make test ONLY_TESTING=KeroTests/SessionStoreTests` -> PASS，针对性 3/3（随后加入历史键检查）。
- `make test`（Commit `259ac58` 代码完成后） -> PASS，35/35，`build/DerivedData/Logs/Test/Test-kero-2026.10.13_03-33-51-+0800.xcresult`。
- `make build` + `codesign --verify --deep --strict` -> PASS，最终复核日志 `/tmp/kero-observation-p1-t2-final-build.log`。
- `rtk codegraph sync` 后追踪 `requestSave → saveAll → makeWindowSnapshot` -> PASS；`rg autosaveObservation kero` 无旧实现。
- 受控隔离 Debug（1800×1130）原生窗口/AX 对照：顶部、侧栏、中央静态区、右侧树、底栏合计 49,484 个采样像素 0 差异；Shell 登录时间和 PTY 等变化不属于静态像素基线。
- Swift 6 诊断：全局覆盖错误触发第三方依赖失败；隔离 Xcode 工程只改 Kero Target 的诊断退出 65，首次 App 错误 `KeroTerminalView.swift:359`（`deinit` `Timer?`），证据在 `evidence/p1-baseline/`；此处是已知 P7 待办，不以 P1 验收要求冒充通过。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P1 保存事件解耦、真实快照/sidecar 数据检查、构建测试及可复核 UI 基线均成立；未出现需要阻塞 Observation 下一阶段的正确性 finding。

## 最终状态与剩余风险

- 当前状态：`Resolved`（P1 审计完成）
- 剩余风险：实际终端历史重启回放、完整设置/浏览器/Diff/模态框/多窗口焦点视觉交互、Swift 6 生产编译仍待其所属 P2～P7 验收。禁止改动真实用户配置以满足测试，不能将以上未测场景报告为已通过。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-14 独立重审：P1（不继承旧审计结论）

| todo 任务 | 原提交核对 | 当前执行路径／独立证据 | 判定 |
| --- | --- | --- | --- |
| P1-T1 | 基线检查任务，无独立功能提交 | 阅读 plan-p1 与当前源码、真实 scheme；本机未入 Git 的 `evidence/p1-baseline/` 实际保有正式 App、隔离 Debug 的原生截图和构建日志，可在原机查看；但图像不是完整可交互基线，后来 Diff/Files A-B-A 实际串文证明标签切换覆盖不充分。 | **需补真实 UI 比对**；不能以完成标记认定零 UX 差异 |
| P1-T2 | `259ac58` | `TerminalManager.requestSave→saveAll→makeWindowSnapshot`，Project/PaneTab 与文件/浏览器变更触发快照；`SessionStoreTests` 覆盖语义保存、历史 sidecar，代码仍被现行 App 消费。 | 代码与单测可核对；运行中 App 重启恢复待测 |

**额外清理**：P1-F-01 指向两份已不编译的历史身份测试，仍要求早已停止使用的 Kero Dev 包名／数据目录。删除它们及 Xcode 排除列表对应项；现行 `AppIdentityTests` 只验证唯一正式身份。保留真正需要的历史布局 `info` *读取并过滤*兼容分支，删除它会破坏旧用户快照的整体解码。
