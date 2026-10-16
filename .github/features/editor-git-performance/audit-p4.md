# Audit P4 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P4-T1 分阶段交付 Git 核心状态与详情
- [x] P4-T2 收敛详情失效与历史分页工作
- [x] P4-T3 预聚合共享树状态装饰
- [x] P4-T4 验证并收敛文件树刷新成本

## 任务到文件的映射

- P4-T1（167be14）：GitStatusModel 的 core/details、执行前校验与缓存；GitPanel／BottomToolbar；RemoteCommands／RemoteConnection 的有限批次与预算；GitStatusModelTests、RemoteCommandsTests、RemoteLifetimeTests；git.md、ssh.md 与文案。
- P4-T2（56fa227）：GitStatusModel 的 full/indexOnly/historyOnly 刷新需求升级、分页一致性与最后事件合并；GitStatusModelTests 真实临时仓库；git.md。
- P4-T3（cb1a245）：GitStatusModel 的 fileDecoration/applyRepository/clearRepositoryState；GitStatusModelTests 对照旧全量扫描、同路径双业务行、真实冲突；files.md。
- P4-T4（618c77b）：ToolPanelView.PanelSyncQueue 与 FileTreeModel.sync/rebuild、文件创建/重命名身份保护；PanelContextTests、FileTreeTests、TreeRowHitTestingTests、RemoteCommandsTests；files.md；独立实验和 Red／Green 日志见 evidence-p4.md 与忽略的 build/performance/editor-git-20261016/。

## 发现项

沿四笔真实提交、生产调用路径、对应消费者、原生／集成测试与当前功能文档重新复核，未发现尚未处理的确定性生产代码缺陷。T4 实施期间通过 Red／Green 修复两处已复现问题：旧 SSH 请求阻塞新目标且发布旧行；同路径换 backend 保留旧草稿并可误向旧通道创建／重命名。它们已有对应提交和永久回归，不重复登记成 Open finding。

- **独立 App GUI 验收缺口**：隔离窗口可读取，但后台 AXPress 返回 INTERACTION_FAILED / effect=unverifiable，复查仅有 partial semantics。Files、Git 工作区、暂存区及历史区域的实际菜单、滚动、悬停、窄栏与无障碍不能声称完整 E2E 已通过。归 P6 整机验收，不冒充代码已发现 bug。
- **真实 SSH 验收缺口**：未获得本轮专用获准的 SSH 主机；3 个真实 SSH 用例按测试要求跳过。受控后端仅证明逻辑、不能证明真实网络延迟或断线恢复。
- **性能边界**：T3 提升状态装饰查询而非完整屏幕 FPS；T4 本地目录轮询有成本，但远端实测缺失，不额外引入 batch、mtime 缓存或 watcher。

## 修复日志

- P4-T1：核心／详情先后交付、详情资格边界、SSH 批次失败不回落、统计容量与预算；同任务修复过度门禁阻断真实 Tag→Push 和恢复路径，没有逐点增设绕过。
- P4-T2：按已知 stage 和历史分页缩小查询，保留完整刷新和请求升级；替换旧分页全量重读。
- P4-T3：目录装饰预聚合与忽略集合查询取代逐行全量扫描；同时修复已删除叶子因 /private/var 词法路径规范化导致装饰查不到的错误。临时性能测试没有入正式目标。
- P4-T4：PanelSyncQueue 在目标变化时立即执行新闭包，同目标合并最后刷新；FileTreeModel 以现有遍历代次失效旧通道数据／草稿／写入，不增加第二套树、SSH runner、TTL、预取或监听。保留原有 symlink 循环深度限制、排他创建与读取失败展示。
- 本轮审计未发现需要再修复的独立新 Finding；以前的 Red 和修复属各自任务证据，不改写历史提交。

## 验证日志

- P4-T1：p4-t1-full-recheck.log 为 290 tests／0 fail／3 SSH skipped；Debug 与 Release 签名通过。
- P4-T2：p4-t2-final-full.log 为 294 tests／0 fail／3 SSH skipped；Debug 与 Release 签名通过。
- P4-T3：p4-t3-full.log 为 296 tests／0 fail／3 SSH skipped；Debug 与 Release 签名通过。同样本各30次目录状态查询由14.876ms降至0.690ms，文件行查询22.654ms降至3.027ms，仅是模型查询中位数。
- P4-T4：p4-t4-verified-full.log 的 make test 为 **304 tests／0 failures／3 dedicated SSH skipped**；PanelContextTests 9、FileTreeTests 7、TreeRowHitTestingTests 5、RemoteCommandsTests 10 均 Green；make build、make build:release 均 BUILD SUCCEEDED 且严格 codesign 验签通过。
- 原生/外部结果：真实本地 Git 行、冲突、分页与写入副作用；本地文件的创建／重命名／删除、symlink／broken／cycle、暂不可读目录；受控异步 SSH fixture 旧任务返回后不得覆盖新结果或写入旧通道。红绿日志、固定样本与30轮成本都在 evidence-p4.md。
- 独立 Debug App 以 --isolated-ui-test 启动（PID 35438，window 96844）且与用户进程 PID 18952 分离；Peekaboo 能读 AX 元素但不能证实后台点击，未抢用户焦点，退出了自建隔离实例。签名 Debug 已同磁盘暂存、整包替换和复验安装到 /Applications/Kero.app，新旧二进制 SHA 不同；用户原进程未重启，不能说运行中窗口加载了新代码。
- 文档归属与导航：docs/features/git.md 负责 Git 核心、详情、分页和容量；files.md 负责树、连接切换、操作；ssh.md 负责远端绑定；testing.md 和 development.md 仍是测试、构建、安装的唯一规范；docs/README.md 导航均有相应 owner，无第二份验证清单。复核发现 ssh.md 指向已不存在的历史 P4 证据目录，由单独文档提交 44c8500 修复；对上述 7 个相关入口复检，无失效相对文件链接。

## Gate（是否允许进入下一阶段）

- 结论：**Go（允许进入 P5；不代表完整独立 App／SSH E2E 已完成）**。
- 理由：四项任务已按实际证据实施、接入与清理，最终自动回归、原生组件和构建验签通过，未发现尚未修复的确定性阶段代码问题；独立 GUI 和专用 SSH 的不可测边界保留在 P6 综合验收，不将任何未执行操作写成通过。

## 最终状态与剩余风险

- 当前状态：P4-T1～T4 全部 Completed 且已有真实提交；阶段 Go，无产品代码 Open finding。
- 剩余风险：隔离 App 的真实菜单、窄栏、悬停、横滚、键盘与无障碍 E2E 尚未验证；真实获准 SSH 未运行，3 项跳过。正式包已安装，但用户运行中的 Debug 进程未重启。P7 上游 Tree-sitter 迁移的候选 No-Go 只禁止引入该插件，不影响在保留现有 Neon 情况下开展 P5 原生 Diff 工作。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

