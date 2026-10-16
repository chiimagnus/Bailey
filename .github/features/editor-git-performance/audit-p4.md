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

## 发现 F-47

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/SSHWorkspaceBackend.swift:196`
- 摘要：`mv -n 在目标路径竞态变成目录时会把源文件移动到其内部并误报重命名成功`
- 风险：`真实 macOS shell 已复现源路径消失，文件变成 dest/source；目标由并发进程创建且仍无覆盖的假阳性`
- 预期修复：`成功后校验目标目录语义并还原误移入目录的源文件；同时处理普通路径及大小写中转路径`
- 验证：`RemoteCommandsTests 受控并发创建目标目录 Red->Green，Windows SSH 实际外部更名回归`
- 解决证据：`修复 7beaea7；Red: 目标在检查后变为目录使源文件及源目录被移动进目录，测试失败；Green: portable ls -id 核验实际移动后目录项身份并恢复误移入路径，RemoteCommandsTests 13/13，Windows SSH 实机成功。`


## 发现 F-46

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/SSHWorkspaceBackend.swift:165`
- 摘要：`大小写重命名的临时阶段遇到远端命令中断可使源路径消失并遗留隐藏目录`
- 风险：`注入首次移动后中断复现：文件仍在临时目录但原始源路径不存在，界面返回失败且文件不可见`
- 预期修复：`为带临时目录的重命名阶段添加 shell EXIT/信号回滚与有界清理；故障时恢复原始路径且不覆盖并发文件`
- 验证：`RemoteCommandsTests 注入临时阶段中断 Red->Green；实际 macOS shell + Windows SSH 目录副作用复核`
- 解决证据：`修复 7beaea7；Red: 退出和 SIGTERM 后源路径消失、临时目录残留；Green: EXIT/HUP/INT/TERM trap 恢复源、删空临时目录，RemoteCommandsTests 13/13；SIGKILL/断电不承诺回滚，已在 files.md 标注。`


## 发现 F-45

- 任务：`P4-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Remote/SSHWorkspaceBackend.swift:166`
- 摘要：`重命名引用 GNU stat -c 导致 macOS SSH 远端相同文件别名重命名失败`
- 风险：`Mac remote shell 使用 BSD stat，不支持 -c；当前测试替换了该调用而掩盖兼容问题`
- 预期修复：`改用在 POSIX 兼容 shell 可工作的同实体判断，不依赖 GNU stat`
- 验证：`未做命令翻译的 macOS /bin/sh 回归以及 Windows SSH 回归`
- 解决证据：`修复 7beaea7，移除 GNU stat -c 假设；测试不再替换命令，真实 macOS /bin/sh 与 Windows MSYS SSH 端到端正常。`


## 发现 F-44

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/SSHWorkspaceBackend.swift:166`
- 摘要：`SSH 重命名以 inode 相同放行不同目录项硬链接并删除来源名`
- 风险：`同 inode 的 hard link 可复现旧逻辑丢失源路径；跨目标真实数据完整性缺陷`
- 预期修复：`以 no-clobber 保留目标，只有确实映射同一目录项的大小写更名才执行；区别硬链接`
- 验证：`RemoteCommandsTests 真实磁盘硬链接 Red->Green，Windows SSH 真实路径回归`
- 解决证据：`修复 7beaea7；硬链接相同 inode 不允许重命名覆盖。RemoteCommandsTests 13/13；真实 Windows SSH 重命名正常与硬链接碰撞通过；Debug/Release 严格签名成功。`


## 发现 F-43

- 任务：`P4-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:484`
- 摘要：`已核验的 Stash 列表仍被无关的 Ref 元数据失败禁用`
- 风险：`Ref 查询短暂失败即使 stash list 已成功，也无法 Apply/Pop/Drop 真实 Stash；无关详情错误互相拖累`
- 预期修复：`仅以可用核心与当前 Stash 列表判断 Stash 操作资格，保留执行前现有 live stash selector/OID 二次校验`
- 验证：`GitStatusModelTests 注入 Ref 失败且 Stash 查询成功；GitStashActionTests 磁盘操作回归`
- 解决证据：`Red: Ref 失败且 stash list 成功时 Stash 资格被禁，单用例 1 failure；Green: 单用例通过、GitStashActionTests 和全量 XCTest 344/344；修复 commit d84579b，删除无关 Ref guard，保留活体 stash/HEAD/target 校验。`


## 发现 F-42

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/SSHWorkspaceBackend.swift:160`
- 摘要：`SSH 重命名把失效符号链接误判为不存在并允许覆盖同名目标`
- 风险：`远端 Files 中合法的 dangling symlink 无法重命名；同名失效符号链接目标可能被 mv 无提示替换`
- 预期修复：`统一在远端重命名原子命令中按链接本身判定源与目标存在性，并保持合法大小写重命名`
- 验证：`RemoteCommandsTests/SSHWorkspaceBackend 真实临时文件路径副作用测试与 FileTreeTests`
- 解决证据：`Red: 旧 SSH  对 dangling link 返回 false，临时目录重现目标链接被 mv 覆写；Green: RemoteCommandsTests 13/13（真实临时文件，包含 dangling 源/目标、case-only），全量 XCTest 344/344（SSH 文件树通过）；修复 commit 48607e5。`


## 发现 F-41

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:3093`
- 摘要：`完整刷新将 Ref/remote 作为核心门槛，查询失败或卡顿阻断有效的 Git 核心状态`
- 风险：`核心 status/HEAD 已成功却显示整仓不可用，stage/commit 被禁，违背核心优先与详情局部失败契约`
- 预期修复：`将 Ref/remote 合并入核心交付之后的有界详情批次；详情故障保留核心、只撤销未验证 Ref 操作资格`
- 验证：`GitStatusModelTests 延迟 Ref 及失败恢复场景，make test ONLY_TESTING=KeroTests/GitStatusModelTests`
- 解决证据：`Red: Ref 阻塞/失败导致核心不可见并禁止工作区动作；Green: GitStatusModelTests 26/26、全量 XCTest 344/344（含 Windows SSH Git 外部刷新）；修复 commit d84579b：将 Ref/remote 移到核心发布后的详情阶段，详情失败保持核心。`


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


## 2026-10-17 P4 独立逐提交复审（本轮）

审查依据为 plan-p4.md、todo.toml、AGENTS/开发文档、本轮 CodeGraph 源码与调用路径、原始提交差异和本轮测试；结论不采用已有审计报告。

| 任务 | 原提交 | 当前产品调用链与核验 | 本轮结果 |
| --- | --- | --- | --- |
| P4-T1 | `167be14` | `ContentView.syncGit` / `ToolPanelView` → `GitStatusModel.refresh` → `runGitStatus` → core `applyRepository` → GitPanel、底栏、Git 动作；SSH 批协议、operation、预算、行数与失效资格 | 发现 Ref/remote 在核心之前阻塞及失败撤销核心（F-41），Stash 被无关 Ref 资格锁住（F-43）；均修复于 `d84579b` |
| P4-T2 | `56fa227` | index-only 已知索引动作的 core+totals，full 刷新排队升级，historyOnly 分页仅核查状态/Ref/log；历史列表操作仍接入 GitPanel | 保留；真实 Git 命令与分页／交错刷新回归通过，未发现值得额外拆分的新旧路径 |
| P4-T3 | `cb1a245` | `GitStatusModel.applyRepository` 构建直接装饰及祖先索引；`fileDecoration` 提供共享树行消费；重复路径仍保留 Git staged/changed 两条业务记录 | 保留；慢扫描 oracle 等价测试与 FileTree/TreeRow 测试通过，未恢复旧每行全量扫描 |
| P4-T4 | `618c77b` | `ToolPanelView.PanelSyncQueue` → `Project.syncFiles` → `FileTreeModel.sync/children` → local/SSH backend `list` → `TreeDisplayModel.Traversal`；目标切换、重建中事件、草稿/写前校验进入真实 Files UI | 发现远端重命名遗漏失效符号链接（F-42），修复于 `48607e5`；其他两级刷新合并各自有独立职责，不予误删 |

### 本轮 Red → Green、验收和清理

- F-41：注入远端 Ref 批次挂起，旧代码核心状态不可见；注入 Ref/remote 失败时旧代码撤销有效核心。拆出详情查询并核对详情错误、独立操作资格；GitStatusModelTests 26/26。
- F-42：临时目录实测原 `[ -e ]` 将失效源链接误判不存在、将失效目标误判空闲并覆盖；改为检测目录项自身及相同 inode 的大小写重命名。RemoteCommandsTests 13/13，包含实际临时文件副作用。
- F-43：注入 Ref 失败但 Stash 列表有效，旧资格限制触发 Red；删除 Stash 对 Ref 的无关依赖，保留活体 HEAD/目标/selector/OID 校验；Green 与 GitStashActionTests 均通过。
- 全量 `make test` 使用 `KERO_P4_TEST_SSH_HOST=windows`：344 tests，0 failures，0 skipped；涵盖真实 Windows SSH 的 Git 外部刷新、实际写操作、FileTree batch、故障恢复；本机 Debug `make build` 和严格 codesign 通过。
- 清理：不恢复核心阶段冗余 Ref 查询、不保留双轨 fallback；删除 Stash 无关安全围栏；保留 P4-T4 两个不同生命期的去重队列、合法 duplicate Git pathRows 及实际执行前校验。
- 范围边界：原生 AX 全流程人工点击和 Windows 真实失效符号链接重命名未独立覆盖；后者已由运行实际 shell 的可控临时文件副作用测试验证。未以此冒充对实际 Windows 文件系统权限与 App AX 的验收。

本轮功能性 Gate：自动化验收通过；原生 AX 与远端重命名的端到端设备覆盖仍属明确的未测边界，不宣称零潜在缺陷。

### 构建、安装及 Gate 补充核验

- `make build`、`make build:release` 均完成；Debug 和 Release 的整包 `codesign --verify --deep --strict` 通过。
- 已按 `docs/development.md#本地安装` 将完整 Debug 构建替换至 `/Applications/Kero.app`：先同磁盘暂存并严格验签，整包移动替换，复验签名；安装后二进制与 Debug 构建逐字节一致，清除本次旧包与暂存，不遗留备份；未结束、启动或重启用户现有 App，新代码下次启动生效。
- 两项独立中文 Git 提交已产生：`d84579b`（P4-T1，含 F-41/F-43）、`48607e5`（P4-T4，含 F-42）。`todo.toml` 中 P4 原四项已完成，不修改其他阶段任务；其他审查人员的文件未进入上述 commits。
- Gate 结论：P4 自动化验收 **GO**（344/344、含真实 Windows SSH），Debug/Release 构建与本地安装 **GO**；GUI 的原生 AX 手工动作、Windows 真实失效符号链接的单独端到端副作用仍为未测边界，不声称已验证。

## 2026-10-17 极端场景独立扩展（第二轮）

此轮未采用旧 audit 的结论；依据 P4 原 plan/todo、当前 CodeGraph 调用路径、Red 失败数据、实际 Mac shell 与授权 Windows SSH 实机回归独立核对。

### 新发现与根因修复

- F-44（High，`7beaea7`）：真实硬链接相同 inode 但有两个目录项；旧远端重命名错误覆盖／移除原路径。加入同 inode 硬链接回归，不能把 inode 相同直接当同一名称。
- F-45（Medium，`7beaea7`）：旧 GNU `stat -c` 在 macOS BSD stat 无效；删除测试里的命令转换，直接由 macOS `/bin/sh` 和真实 Windows MSYS shell 执行同一实现。
- F-46（High，`7beaea7`）：受控中断发生在临时目录中转后，旧实现隐藏源文件且残留 `.kero-rename.*`。Red 复现，再验证普通 `exit 70` 与 `TERM` 的 EXIT/signal 回滚、源路径和数据保持、空临时目录清理。SIGKILL/机器掉电不保证回滚；残留不自动清理。
- F-47（High，`7beaea7`）：并发进程在目标检查后创建目录，`mv -n` 会将源文件甚至源目录移动到此目录内并假报成功；Red 真实文件副作用，Green 用可移植 inode 身份检查并恢复异常嵌套移动。读写和目录检查均以实际文件内容／路径为结果，不仅检查返回码。

### 其它 P4 条件矩阵

- P4-T1：详情 Ref、History、Stash 同时失败与逐项恢复；核心状态独立可用，详情操作资格只由其真实快照验证决定。`GitStatusModelTests` 26/26。
- P4-T2：已知索引变更、外部提交、分页失败、排队 full 不降级、HEAD/Ref 变化后重新取一致历史，相关 Git 测试组通过。
- P4-T3：实际 Git rename、MM、冲突、staged deletion + untracked 同路径、ignore 后代、特殊名称（中文、换行、tab、引号、emoji），另加 1500 确定性路径 × 文件/目录查询与慢扫描 oracle 对照，通过。
- P4-T4：三次目标切换、两个旧 SSH 列表同时阻塞、晚到结果不得覆盖第三目标；`PanelContextTests` 11/11。`RemoteCommandsTests` 13/13，Mac 真实临时磁盘含目录竞态、信号退出、硬链接、失效符号链接及大小写路径。Windows SSH 实机临时目录验证中文和引号、文件／目录占用、硬链接与 NTFS 大小写重命名，实际副作用通过；该测试主机 `ln -s` 返回 1，不能宣称 Windows 原生 symlink 通过。

### 性能和环境证据

- Windows SSH 同目录、同连接 30 轮：两目录逐次请求中位 1.500s、p95 1.557s；合批中位 1.024s、p95 1.089s（节约约 31.7%）。冷树 n=5 中位 2.383s；缓存目录展开／折叠 n=30 中位 0.001s；14 目录刷新 n=30 中位 1.422s。仅代表真实 Windows SSH 链路及后端读取，不冒充 UI FPS。
- 前一次扩展全套 `make test`（真实 Windows SSH）：364 tests，1 failure；唯一失败属当时正在并行修改的 P5 `DiffTabTests.testEditGeometryUsesGitLFLinesAcrossNativeBareCRParagraphs`，不是 P4；对方代码更新后该用例单独复测通过。P4 各 Git、Files、PanelContext、Remote、原生树行、Windows SSH 测试组在该轮全部通过。
- 最终 `make build` 和 `make build:release` 均 BUILD SUCCEEDED + `codesign --verify --deep --strict` 通过。额外 Release XCTest 探索因工程 Release kero 模块未开启 `-enable-testing`，无法 `@testable import kero` 而编译失败；并非 P4 运行期断言，工程既有常规 XCTest 使用 Debug 目标。
- 原生 App 的测试由现有 macOS XCTest UI 测试覆盖；已在用户现有 Kero 进程运行时确认 Peekaboo Accessibility/Screen Recording 权限可用，但未操作或重启用户的旧进程，不能把这当作新安装包的人工 AX E2E 证据。

本轮只提交 3 个 P4 原子提交：`7beaea7`（修复及实机/单元测试＋docs）、`fd731ee`（Git 详情＋装饰矩阵）、`52f840f`（三目标竞态）；未混入其他 AI 的 P2/P3/P5 代码、文档或测试。
