# P4｜阶段审查

审查对象：[P4 实施计划](plan-p4.md)。
实时任务状态以 `todo.toml` 为准。

2026-11-26：分批 PR 合并后，提交引用已校准至 rebase 后的等价提交。
逐个核对原始与新提交的文件树完全相同；既有测试证据仍对应原执行快照，未重新运行。

## 结论

- **结果**：No-Go（本轮本机功能通过；共享远端移列撤销发布 F-12 未核销）。
- **依据**：独立复审四项任务及真实调用链，F-02 经 Red/Green 修复于 `a54a31f6`，最新本机 CSV 核心 53/53；真实 Git Diff、七种文件混合切换、远端冲突保护及单项及混合文件切换同进程远端撤销复验均通过；首次远端不稳定失败仍追踪于 P2。

## 任务与改动

- **P4-T1 列结构／表头**：`b59a23d6`。DelimitedGrid 列菜单和原生表头输入经 FileTab 的唯一原文事务；
  DelimitedTableMutation 重组必要 token，DelimitedTableControls 按已知列身份重映射显示配置。
- **P4-T2 完整字段**：`20dae647`。同一原生输入会话覆盖表头、普通及完整字段；
  失败提议归 FileTab，保持保存／关闭保护，不另建文档或 Undo 历史。
- **P4-T3 批量编辑／查找替换**：`8d1ef42d`。固定 FieldScope 绑定投影；
  复用字面匹配与原文替换链、系统 Find 路由，提交一次并注册唯一 Undo。
- **P4-T4 统计／空值检查**：`2cf61a92`。DelimitedTablePresentation 在后台聚合实际字段，
  CSVTableView 的按需浮层与现有查找共享有效投影；统计不进入 edit/save/Undo。
  本地化及当前功能文档随实现提交。

## 2026-11-26 独立逐提交复审

重新核对 todo 的 4 个任务原提交、后续修复和生产入口。
- P4-T1 `b59a23d6`：`DelimitedGrid.columnMenu`／`renameHeader` → FileTab → `DelimitedTableMutation.prepare(.columns)`；全部物理记录的 raw token 最小范围重组、列数／容量、过滤排序列宽与选区重映射、唯一 Undo。相关索引、真实菜单及字节回归通过。
- P4-T2 `20dae647`：`beginEditing`／`openFullCell`／`beginFullField` 共用 CellEdit 和 FileTab 草稿所有者；长字段、混合换行、只读、标记输入和失败保稿均进入实际挂载原生控件。相关宿主通过。
- P4-T3 `8d1ef42d`：实际 Find 菜单／替换浮层／右键填充及 Delete → FieldScope → `prepare` → 同一原文事务。F-02 复现手动重选 C 行却实际改写 A 行；以真实 caret 定位，继续偏移仅限原格，取消重复定位优先级。当前批量十万行 prepare+apply 0.379 s、Undo/Redo 0.462 s（`/tmp/bailey-csv-audit-green.b8rGMPOC`）。
- P4-T4 `2cf61a92`（功能）及 todo 对应 `c22c3c02`（补强回归）：实际列头／选区菜单 → 按需统计浮层 → `DelimitedTablePresentation.statistics`，复用有限数值与 `find` 的空值路径；百万字段 0.751 s、取消与原文／Undo 不变通过。
- 扩展验证：401e6259 三分隔符 × 九种编码 × 十五种列变换，405 组真实 FileTab 编辑、保存、Undo 再保存和原字节比对；b2a39b51 挂载统计面板从空值谓词切换到普通查询，清空查询不恢复旧谓词。新增定点 3/3 及扩大宿主 176 通过/1 个非 CSV 的 JPEG 长时样本跳过，零失败；真实 SSH 3/3。日志 `/tmp/bailey-csv-audit-expanded.dZRBsvd3`、`/tmp/bailey-csv-audit-expanded-full.I56TByip`。
- 清理核对：旧测试提交旁路、单独 Undo、独立表格持久化、双轨统计/Find 与按格百万字典均不在现行链。菜单可见许可与实际执行准入分离，列变更候选解析、编码及磁盘版本校验有明确独立职责，不无条件拆除。

## 2026-11-26 实际界面复验与交互收敛

用户明确要求去除重复右键入口；当前需求以 idea、plan 和功能文档为准，以上早期审查保留历史证据。
- 删除完整字段、选择此行、选区统计及清空字段的菜单与专属处理；仅多格可批量填充。只读字段改为双击／Return 查看，列统计及键盘清空沿原有链。
- 修改前实际 App 点击批量填充、增删行、插列、移列、删列，保存与撤销字节回归通过（`/tmp/bailey-csv-context-ui-baseline.hDBbUoqD`）。
- 修改后实际 App 排序／筛选／查找／复制、单格编辑／源码切换／Undo 及保存两个用例通过（`/tmp/bailey-csv-context-ui-green.kEycHglw`）。该轮另一用例未找到行号 AX 按钮；改为对准实际可见行号进行鼠标点击，非通过 AX action 代替点击。
- 第二轮使用开发签名，真实列统计／空值导航／单次与全部替换，精简菜单／批量填充／行号选择／增删行列／两种 Delete 与 ⌘A 的保存和一次撤销，2/2 通过，零失败（`/tmp/bailey-csv-natural-ui.ZWRe5C3g`）。
- CSV 核心宿主 53 项：52 项首次通过；列统计新增范围控件后旧窄高夹具未显示最后一项数值，三个断言失败。调整统计用例窗口尺寸后该项 1/1 通过，完整数值、主题与只读原字节均核对。日志 `/tmp/bailey-csv-natural-host.bZGsz0vR`、`/tmp/bailey-csv-natural-host-retest.Lq4b0sw0`。
- 正式 Debug 构建与严格验签通过（`/tmp/bailey-csv-natural-build.1dKj554P`）；未重启正式 App。未穷举所有 GUI 组合、未重新测试真实 SSH，不改变 F-12 的 Open 与阶段 No-Go。

## 发现项

## 发现 F-02

- 任务：`P4-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/DelimitedTablePresentation.swift:325-349; Bailey/Editor/CSVTableView.swift:470-499`
- 摘要：`单次替换优先沿用上次命中物理格，手动重选其他格后仍修改旧格`
- 风险：`连续替换后用户明确选择其他可见格，下一次替换仍从旧格开始，造成非预期字段改写`
- 预期修复：`以当前原生 caret 为定位所有者，仅 caret 仍位于上次格时复用其字段内偏移；不增加导航状态`
- 验证：`同格连续替换与重选另一格后的精确命中、真实 FileTab 事务、原文字节及单次 Undo`
- 解决证据：`a54a31f6ff2fcb8149627c3d10fab83a219d5552；Red /tmp/bailey-csv-replace-audit-red.ii2nUTyy（3 条断言失败）；Green /tmp/bailey-csv-audit-final.kSRdvSR2（真实 FileTab 同格续替、重选格、精确写入及 Undo 通过）；正式构建 /tmp/bailey-csv-audit-build.Da8FESBm。`


## 发现 F-01

- 任务：`P4-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Files/DelimitedGridInteractionTests.swift:449`
- 摘要：`原统计宿主只确认菜单动作成功，未核对已挂载浮层的真实统计值、空值命中及导航`
- 风险：`即使数据算法正确，若统计浮层不发布或查找导航接线错误，原测试仍会通过`
- 预期修复：`沿同一原生菜单和浮层测试实际结果、空值计数与两处命中间导航，同时核对原文和磁盘不变`
- 验证：`make test ONLY_TESTING=BaileyTests/DelimitedGridInteractionTests/testReadOnlyGridOffersSelectionStatisticsWithoutAnyEdit SIGNING=adhoc`
- 解决证据：`c22c3c02；真实挂载统计8组数值、深浅主题、两处空值导航、未修改原文件/dirty/Undo；47/47与独立CSV Dev62/62、ad-hoc严格验签退出0；/tmp/bailey-csv-p4-final-green.xMoIxSdP、/tmp/bailey-csv-dev-audit.rxI5gze1`


## 验证与未覆盖

- macOS 27.3（26C5035r）／Xcode 27.2（27B5038j）／arm64，源码 `c51599d6`：
  `make test:DelimitedGridInteractionTests,DelimitedTablePresentationTests,DelimitedTableIndexTests SIGNING=adhoc`，
  46/46、零失败，退出 0（含 App／XCTest 严格验签）；日志 `/tmp/bailey-csv-p4-resume.ovGk4NRX`。
- C18：列结构、隐藏行、列设置重映射、原始 token、混合行尾、BOM、真实保存及 Undo；
  先前 40/40、真实 Windows SSH 2/2，日志 `/tmp/bailey-csv-p4-columns-final.eUJdV0MZ`、
  `/tmp/bailey-csv-p4-structure-ssh.qW5mPo0L`；当前网格和索引类重跑通过。
- C19：原生短／长字段、只读、4095／4096／4097 UTF-16、混合换行、主题与失败保稿；
  先前 38/38（含原生编辑组合），日志 `/tmp/bailey-csv-p4-long-final.pzprxYIS`；当前网格／投影回归通过。
- C20：真实 Delete、固定范围、重叠、Unicode／混合换行、计数、一次 Undo／Redo、Find 路由；
  先前 47/47、真实 Windows SSH 2/2，日志 `/tmp/bailey-csv-p4-batch-final.DHlmqb1h`、
  `/tmp/bailey-csv-p4-batch-ssh.E1QF31n2`；当前 100000 行准备与提交约 0.372 s，Undo／Redo 0.458 s。
- C21：按真实字段统计空串、空白、缺失、有限数、下溢／溢出、极端抵消、重叠、筛选、部分坏表；
  百万字段 0.689 s、取消通过，统计不修改原文件。F-01 已通过真实挂载浮层数值、空值导航及深浅主题复验；
  全部／可见列范围算法已覆盖三种分隔符，范围控件实际切换及失效时序仍需专项实测。
- C22：此前真实 Windows Tailscale 结构／批量保存、断线重连、冲突及实际字节通过；
  当前索引回归含已接受编辑、编码、旧快照、项目关闭和本机真实文件。
  本轮重复真实远端写入及冲突验收通过，首次不稳定失败 F-12 仍开放；未覆盖全部跨窗口组合。
  非协作严格 CAS 仍沿 P2 的既定延期。
- C23：100000 行／2501／4095／4096／4097 列及最后可见格；
  100 次十万行编辑 17.261 s，单次 edit p95 0.079 s，主线程 Undo p95 0.0037 s；
  100 次挂载 0.510 s，RSS 峰值前后均 427376640 B。当前索引容量、编码及取消测试均通过。
- 用户排除完整 App GUI 及全量宿主测试；不占用正式 App、前台键鼠或系统设置。
  实体 IME 候选、完整 App 多窗／窄 Dock、系统外观切换及外接 1×、旧 macOS、真实睡眠无本轮实测；
  由既有挂载原生输入、组件像素和窗口宿主提供替代证据，不能记作 E2E。
  获独立图形会话或对应硬件后才补验；F-01、F-02 已关闭；独立逐提交复审已完成，首次不稳定远端发布 F-12 见 P2；未执行完整 App GUI 的组合验收另列。
- 同一 `c51599d6` 源码的正式 Debug `make build` 退出 0，严格验签通过；日志 `/tmp/bailey-csv-p4-build.biiFMZvG`。
- 独立 CSV Dev 使用临时源码快照、专属 App/XCTest Bundle ID、配置和测试锁；不变更正式工程身份。
  身份及会话隔离加 CSV 宿主 62/62，日志 `/tmp/bailey-csv-dev-audit.rxI5gze1`；
  后续分隔符 `0897e227`、查找导航 `2a5408d5` 修复后核心 49/49，日志 `/tmp/bailey-csv-find-green.cSZoBuQP`。
  最新正式 Debug 构建及严格验签通过，日志 `/tmp/bailey-csv-find-build.LtUMXNbQ`。
  不安装、不重启正式 App。功能文档 `docs/features/editor.md` 已核对，计划和审计纳入本地 Git，未推送。
