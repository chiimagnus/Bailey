# P5：原生 Diff 正确性与完整流水线实测

**目标：** 原生 Diff 的行／范围正确，读取不吞失败或卡住加载，再减少真实首屏、滚动和编辑成本。
**不做：** 恢复 Pierre／WebKit／JS、移植旧 hash 修复、增加新差异引擎、永久 blob cache 或全项目多文件 Diff。
**前置／顺序：** P1；T1 初步归因 → T2 分行契约 → T3 读取收尾 → T4 选中性能措施。测 CRLF 正确结果须用 T2 修复后基线，不能把错误少算行当提速。
**验收：** 五种 Source、Unicode／容量／失败／编辑与重挂载正确；采用优化有可复核的首屏与工作量对照。

现有 DiffTab 拥有 nativeSurface。refreshWhenSelected 跳过历史／首次在途，但 Project.openDiff/openHistoricalDiff 复用分支仍直接 reload；不能把“导航选回”与“再次点击 Git 行”混为一谈。保存、只读和源身份不可删；不要把 5 MiB 显示上限和 review 离线高亮 1,500,000 字节策略混淆。

<a id="p5-t1"></a>
## P5-T1 原生流水线归因与候选选择

**类型：** 本地实验。
**完整入口：**
- `kero/Workspace/Project.swift` 的 openDiff/openHistoricalDiff/makeContent、保存后 reload；WorkspaceDockView → PanelContentView → DiffViewerView。
- `kero/Git/DiffViewerView.swift` 的 reload、gitContent、readWorktreeFile、recomputeDisplay、expandRun、refreshEditDecorations／refreshNativeAppearance。
- `GitHistoricalFileLocator.swift`、GitCommandExecution、WorkspaceBackend 本机／SSH 实现。
- `DiffEngine.swift` 的 splitter／DiffCore／DiffComputation／intraline，`DiffSyntaxHighlighter.swift` 的 context／captures／attributedDocument。
- `DiffNativeSurface.swift` 的 render／持有表面，`DiffTextView.swift` 的文档安装、ghost spacing、几何、gutter／underlay、滚动与 TextKit 补丁。
- 当前 XCTest：DiffTabTests、GitHistoryFileTests、PaneRetentionTests；本地证据 evidence-p5.md／build/performance/diff/。

**当前事实：** Git 读取与 core/captures/build 已有后台边界；不是所有工作都在 MainActor。display 计算先等待 query context，再算 core／两侧 captures；统一／左右／edit 派生结果有重复工作，三份 attributedDocument 在 MainActor。expandRun 已复用 core/runs，不能再实现一份“展开缓存”。appearance 刷新会重走计算；edit 的 120ms debounce 不等于已取消开始的 detached parse/diff。

1. 选 P1 固定的首次／live 再选／历史再选／edit-review／多标签路径，分别测 Git／worktree／解码、core、captures、派生文档、attributed 构造、TextKit 首屏／布局／滚动／编辑。
2. 实际用户可见终点用原生内容／光标／操作记录确认；display 非空、NSView 安装或回调完成只作阶段标记，不当成绘制。只采集 Kero 和本轮数据，不追网页进程。
3. 先按 trace 排序：重复读取、等待查询阻塞首屏、非当前布局派生、属性构造、appearance 全重算、在途积压、edit 几何从文首计段落都是候选，不是必做清单。
4. 对最主要热点只做一个最小原型；可复用当前 core／inputs／display/edit generation 和稳定快照就不增加缓存／调度服务。无证据不改变 diff 算法阈值、折叠、高亮或编辑质量。
5. 回写 T4 的实际选择、文件、正确性回归和指标；未命中留保留理由。正确性缺口 T2／T3 不因慢路径未命中而跳过。

**交付／停止：** 一轮定位加一个候选，不能归因先修观测；记录真实首屏／可编辑／高亮策略和内存。没有代码变化不提交，必要 Debug 标记沿 P1 的最小范围验证。

<a id="p5-t2"></a>
## P5-T2 修复共享 LF／CRLF 分行契约

**类型：** 正确性实现，不设性能门槛。
**文件：** `kero/Git/DiffEngine.swift` 的 DiffLineSplitter；受影响的 DiffCore／DiffComputation、DiffDecorations／geometry 作为消费者核对。扩展 P3-T2 已接入的 `KeroTests/Unit/Git/DiffEngineTests.swift` 和现有 DiffTabTests 原生多行验证；文档归 `docs/features/diff.md`，保留 P3-T2 的字节精确比较。

**根因：** 当前逐 Swift Character 比 LF，CRLF 是一个 Character，不会命中，多个物理行可能被当成一条。旧原生测试只要求有增删／左右等高，不能证明正确分行。

1. Red 断言精确行文本、utf16Range、hasTrailingNewline、ops 重建及旧／新行号：空、单 LF、CRLF、混合 LF/CRLF、裸 CR、尾换行差异、中文／emoji／组合字符。明确依现有契约只按 LF 分行，CR 留原内容，不规范化磁盘字节。
2. 使用 UTF-16 code unit 或 Unicode scalar 的 LF 边界遍历，保持原 Substring／源范围语义；删除 Character 分行旧路径，不留兼容算法／开关。
3. 单行 diff、词级强调、折叠展开、统一／左右文档、编辑 added/ghost 的范围同样对齐；不能仅修显示字符串后让 sourceRange 仍错。
4. 原生多行 CRLF 检查行号／装饰对应真实 TextKit 行、双栏对齐与滚动；编辑、undo／保存保留原字节。bare CR／Unicode 分隔符与 TextKit 段落不同的现存契约要核对，不能以新归一化静默修改用户文本；发现实际错位在相同消费者闭环。
5. `make test ONLY_TESTING=KeroTests/DiffEngineTests`、DiffTabTests／GitHistoryFileTests，再完整完成流程及隔离 App CRLF review/edit 验收。语言语义一次性核验不代替这些测试。

**提交：** splitter、必要消费者修复、回归和文档独立提交；随后补可比较的 CRLF 性能数据，不把正确性修复混成性能收益。

<a id="p5-t3"></a>
## P5-T3 收敛读取身份、错误与加载收尾

**类型／依赖：** 正确性必修，读取性能措施按 T1；P2 共享 backend 契约、T2。
**文件：**
- DiffTab.reload／setEditing／updateEditedContent／setReadOnly／save／refreshWhenSelected，以及原有 Git／worktree reader。
- Project.openDiff/openHistoricalDiff 的复用分支只按已测重复读取调整；GitHistoricalFileLocator 的真实 rename／missing／failed 语义保留。
- 不强制新建 DiffContentReader；只有纯数据后台职责确需独立才迁出，与接入／旧 reader 删除同 task，不能为独立脚本或测试壳拆文件。
- 扩展 DiffTabTests、GitHistoryFileTests；GitExecutionTests 和 WorkspaceIdentityTests 按实际共享影响运行。读取算法纯数据提取后才考虑同目标内 Integration 测试，不建立 shell runner。
- 文档归 diff.md；backend／连接契约变动同步 editor.md／ssh.md，不能延至 P6。

**当前事实：** gitContent 已检查 size 与原字节，且只有部分特定 stderr 判 missing；reload 已有 editing/dirty 守卫。保留这些已实现结果，不再按旧计划“任意错误都为空／没有编辑检查”重修。

1. Red：复用现有受控 read，在 reload 后输入使 generation 改变，完成旧读，再撤销／保存／复选，检查 isLoading 结束且能够重新读取。现有测试只检查未覆盖编辑，漏了旧任务在清 loading 之前退出的路径。无输入只进入 edit 的路径已有测试，继续保留。
2. 在 DiffTab 的加载拥有者统一 begin／失效／结束，edit／保存／断线使读取失效也要结束属于它的 loading；旧任务不能结束新任务的 loading。不加第二套 render 身份、独立 coordinator 或到处补调用点 guard。
3. 保留发布前 editing／dirty／readOnly／代次检查，不能用 .noChange 或中间空内容掩盖失效。重连仅原机器，关闭后独占工作有界，不保留第二份缓冲。
4. 收敛真实 missing／失败与可变 spec：成功的 index metadata 用 literal ls-files --stage -z 选 0／2／1 OID，tree metadata 用 literal ls-tree -z，固定 OID 后再读 size／blob；成功空记录才是路径缺失，启动／权限／超时／坏 size／短读都是错误，不凭模糊 stderr 继续 fallback。
5. unborn 与历史 parent/A/D、工作区真实删除仍是合法空侧；冲突 index→stage 2→1→HEAD 是业务选择，不是旧版本兼容分支。HEAD 不存在与命令失败需精确区分，不能把任意 exit=1 都当 unborn；特殊路径按 NUL 解析，不按换行切。
6. 原始字节先检查 5 MiB、NUL、UTF-8，size/content 与同一 OID 对应，失败不被另一侧成功清掉。symlink 显示其目标、不作为普通文件原子覆盖。worktree 解码确认明确离开 MainActor；GitCommandExecution.runData(backend:) 的 @concurrent 已存在，不能重复加后台包装。
7. T1 证明重复读取才统一 Project 复用与选择入口：不可变历史无需无益重读，live 仍刷新外部变化，首次在途请求不重复。不预建批量 cat-file 协议／进程池／永久 cache；必要的独立两侧并行至多有限，不并行试 fallback。
8. 同 task 删除 stderr 猜缺失与被结构化 reader 替代的旧 spec 分支／冗余 isUnmerged 查询，不留旧 reader 恢复通道。保留 shared runner／登录 shell 环境与必要原始字节上限。remote stdoutLimit 仍是返回后截断，不宣称已经限制传输内存。
9. 同 task 补派生内容的真实身份回归：内容 A 已显示，reload 取得 B 并开始 recomputeDisplay，但 query／计算未完成时激活 A 的 fold。当前 expandRun 可读取旧 displayInputs、增加 displayGeneration 并取消 B，最终重新发布 A。新内容接管时使旧 inputs 不再可用于新发布，展开只接受匹配内容的 inputs／fold；复用现有 display 身份／代次，不另造版本框架或重建 nativeSurface。断言最后 display 的行／文本来自 B，旧颜色和编辑装饰也不能重新成为真源。此正确性修复不等 T4 性能准入。

**验证：**
- `make test ONLY_TESTING=KeroTests/DiffTabTests`、GitHistoryFileTests、相关共享回归及完整完成流程。
- 临时 Git 五种 Source、root/unborn/untracked／rename／deleted／unmerged；坏 metadata、命令失败／超时／短读，空／Unicode／NUL／非法 UTF-8／cap／cap+1／symlink。oracle 用 Git blob 和真实磁盘，不复制 reader 算法。
- 原生 reload 中输入／撤销／保存／复选、断线与同机器换连接，检查最后内容、loading、undo 和磁盘；不能只看 guard 返回。
- 共享 SSH 分支改变必须用专用获准 fixture 实测；模拟只证明乱序／错误逻辑。对照 T1 记录读取／进程／往返与可见等待。

**提交：** 读取收尾、身份／错误、真实接入、旧路径删除、回归和文档独立提交；不夹带 T4 未验证的渲染架构。

<a id="p5-t4"></a>
## P5-T4 接入实测选中的原生性能措施

**类型／依赖：** 条件实现；依赖 T1 选择和 T2／T3 正确性复测。
**文件：** 仅 T1 命中的 DiffTab 派生／样式流程、DiffComputation／DiffSyntaxHighlighter 或 DiffCodePaneView 真实拥有者；不预定新服务／缓存文件。测试扩展 DiffEngineTests／DiffTabTests，文档归 diff.md；真实 STTextView 补丁变化才同步 development.md。

1. 先写具体命中阶段与原型证据，再改正式路径。优先现有输入复用、只做必要派生或用现有 generation 丢旧结果；不把候选全部同时实施。
2. core／captures 已在后台，不再加“把 Diff 全部放后台”的包装。若 MainActor 属性构造主导，先减少无关文档／重复构造；NSColor／NSAttributedString 等 AppKit 对象不能无依据标 Sendable 送后台。
3. 若 query 等待主导，验证先显示正确内容、稍后颜色的最小分阶段结果；不能让旧颜色覆盖新内容，不能把 plain 首屏冒充高亮完成。沿 P3-T5 实际共享 cache，不复制编译器。
4. 若 in-flight 或 edit geometry 主导，复用已有 display/edit 状态和稳定快照做最少调度／计算；Task.cancel 不代表 detached 工作已停止，必须测在途数量、读量和关闭后释放。没有证据不建全局线程池／新版本框架。
5. 保留 DiffCore/runs 的既有展开复用、原生每 tab 唯一表面、undo／选择、折叠锚点、固定行高、两轴滚动边界与重入 guard、零范围／范围裁切、只读／保存保护。这些不是多余兼容代码。
6. 先保留／补本次替代的绿色等价基线；新增异步行为或真实缺陷再按 Red／Green。必要时控制旧／新计算顺序和关闭／主题／布局／内容变化，检查最终原生内容、颜色、行／词、loading、滚动和实际保存。不只断言分支／计数，不为性能目标制造错误行为断言。
7. 运行相应上述 XCTest 类、make test／make build，再隔离 App 同样本测首屏、输入／高亮追上、滚动、峰值和关闭后内存。不移动等待后端到端更差；无净收益撤回原型，不降质换数字。
8. 同 task 删除被替代的重复派生／全量重算／旧任务路径，临时实验开关不进入产品。保持 UI/UX，不顺手改文案／布局或算法近似阈值。

**提交：** 实测选中的一个独立结果、回归和文档原子提交；无热点则只有本地保留理由，不 vendoring、不制造空实现。

## 阶段核销

确认真实文件／index／历史来源、原生内容、只读和滚动；性能用 T2／T3 正确性基线对照。没有网页、JS hash、worker 或桥接验收项。实施后才创建阶段 audit，本次没有运行／性能 Gate。
