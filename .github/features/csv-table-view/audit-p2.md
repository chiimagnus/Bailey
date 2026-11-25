# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：原生编辑、Undo、有版本保存及断线草稿恢复已通过真实宿主回归；新发现的编辑事务归属与基线证明已修复（8488bb8a），8488bb8a 完整宿主 1422/1422 通过；本轮新增编码发布竞态与真实原生菜单已完成定点修复，完整 GUI 复验仍待。非协作 CAS 与独占完整 App 按用户决定延期，不替代原验收。

## 任务与改动

- **P2-T1 对原文源区间执行原生编辑、复用唯一 Undo**：FileTab、原生表格与 TextKit 共用文档和 Undo；100001 条记录、100 次编辑／切换和 Undo／Redo 有宿主证据，完整 App 的中文 IME、快捷键与 GUI 性能待验。
- **P2-T2 严格往返编码、条件保存和外部冲突**：FileTab、DiffTab、TextFileEncoding、WorkspaceFileVersion 共用原字节版本和提交确认；重连保留在途快照，不盲目重复写入。

## 发现项

## 发现 F-08

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`DelimitedTableMutation.prepare; DelimitedTablePresentation.copy`
- 摘要：`清空单列末字段或复制末尾空单格时，裸空字符串无法表示独立记录；混合 CR/LF 在清空后也可能融合。`
- 风险：`表格编辑或复制粘贴会少一行；外观无异常时仍可能留下旧目标值。`
- 预期修复：`仅在裸空字段会丢失记录时显式引用，在真实原文及剪贴板往返中保留行列数。`
- 验证：`DelimitedTablePresentationTests：真实 FileTab 源码、Undo、重读磁盘；复制选区后实际粘贴并检查目标内容。`
- 解决证据：`f2f35ff3：本机 macOS 27.3 / Xcode 27.2，原生验证器链接实际 Dev 产品；16 种首尾换行组合（无/CR/LF/CRLF）、已引用字段、多列尾格、连续与非连续删行、末尾空单格及多行复制粘贴等 23 组，旧版失败 10 组，修复后 23/23。核对实际 FileTab、Undo 恢复 clean、Redo、保存读回原字节及重解析行数。修复后 dylib SHA-256 867ead5253f75dd2c4915d3f38b3883ceed2c44917b6c77f795d18b935238839；证据 /tmp/bailey-csv-shape.OrF8Dm/{red,green,typecheck}.log，签名构建 /tmp/bailey-image-keys.zhzd2N/build-dev.log。三项新增宿主用例类型检查通过；make test 实际停在 Xcode 枚举，2m27s 定点中止，未执行，不能记为通过。同版签名 Dev 隔离真实 GUI：双击进入单列末格、通过 AX 清空、文件菜单保存，元数据和实际磁盘字节 `4e616d650d0a2222` 核对一致；正常退出并在新进程恢复同一测试会话，仍有一个空单元格及相同磁盘字节。证据 /tmp/bailey-csv-shape.OrF8Dm/gui/{one,field,after-clear,after-save,cold-reopen}.json。后台热键投递未生效，不计为键盘验收；未改写系统剪贴板，复制粘贴由原生验证器覆盖。完整中文 IME、跨窗编辑冲突、GUI 性能及 F-02 原边界不变。`


## 发现 F-07

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/CSVTableView.swift:641-651; BaileyUITests/Editor/CSVPreviewUITests.swift:221`
- 摘要：`完整 App 原生表格获得键盘焦点且已成功编辑，但系统 undo:/redo: 菜单禁用，实际 Cmd-Z 未撤销`
- 风险：`原生共享 UndoManager 中的网格编辑无法由系统菜单或键盘访问`
- 预期修复：`在 DelimitedNativeTable 原生 responder 提供 undo:/redo: 标准命令与验证，复用 FileTab 唯一 UndoManager；不注册第二套快捷键或全局路由`
- 验证：`真实挂载原生表格，以系统 undo:/redo: selector 执行和校验菜单启用、源字节与原生 Undo；完整 App 复跑 CSV 跨模式快捷键用例`
- 解决证据：`9b62d36c：原生表格 Undo/Redo selector 与验证复用 FileTab 的 UndoManager；修复后本机隔离 Bailey Dev 完整 App 真正排序编辑、Cmd-Z/Redo、源码编辑、BOM/混合行尾精确保存及重开通过，CSV 6/6（161.775s），无跳过。/tmp/bailey-seven-local-ui-e05e3732-20261125.log。`


## 发现 F-06

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/FileViewerView.swift:495-515,1237-1355`
- 摘要：`后台准备已接受的网格输入期间，显式编码保存可确认发布并改变 fileEncoding，虽原文代次未变，准备结果仍被拒绝`
- 风险：`合法且可往返的新字段可能被丢弃，仅显示表格编辑错误；违反 C11×C12 保存中继续输入的约束`
- 预期修复：`先通过受控写入确认与真实大字段事务复现，再在 FileTab 的文档事务／编码发布边界修复；不增加独立保存队列或放弃严格编码校验`
- 验证：`FileTabPersistenceTests：编码转换在途接受原生网格事务，释放受控写入，验证单一原文、Undo、后续保存真实编码字节；相关编码、保存、网格与生命周期回归`
- 解决证据：`9b62d36c：受控真实写入回执期间接收 2 MiB 中文粘贴，旧版 Red 3 断言失败，修复以接收时编码验证事务、原文代次决定提交，编码发布不废弃草稿。UTF-16 LE BOM 转换后精确保存；Latin-1 转换后拒绝无法无损表示的后续保存、原磁盘字节不变、改 UTF8 BOM 后精确保存；两组均核对唯一 NSTextStorage 与 Undo/Redo。最终四项专项与243项受影响宿主回归零失败零跳过（含真 Windows CSV 与图像旁车），Dev/UI构建及Release严格验签通过。日志 /tmp/bailey-seven-csv-image-undo-red-v2-20261125.log、/tmp/bailey-seven-native-undo-and-encoding-green-v2-20261125.log、/tmp/bailey-seven-undo-affected-20261125.log。`


## 发现 F-05

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/FileViewerView.swift:397,419,1330; Bailey/Editor/CSVTableView.swift:77`
- 摘要：`保存更新原字节版本但原文代次不变，已挂载网格的索引和旧基线证明被捆绑，普通保存及显式编码保存后无法再次开始编辑`
- 风险：`保存后网格仍显示正确内容但无法继续修改；进行中的正常保存也可能使已接受编辑失效`
- 预期修复：`在接受文件加载或确认发布时建立严格往返证明，网格索引只绑定唯一原文编辑代次；修改前读取当前编码与基线证明，准备后验证仍有效`
- 验证：`同一真实 AppKit 网格在普通保存及UTF16显式保存后无需重新挂载即可编辑、保存实际字节；回归多编码、并发保存、陈旧索引和未往返编码拒绝`
- 解决证据：`8488bb8a：原字节往返证明属于实际接受的载入或发布基线，原文索引仅绑定文档与展示请求代次。真实挂载同一 AppKit 网格在普通保存与 UTF16 显式保存后继续编辑；Red 4 断言失败，11 项表格展示专项及 26 项联合专项通过。显式 UTF8 解码丢 BOM 时拒绝网格编辑，同文无 BOM 刷新恢复、外部恢复 BOM 再拒绝、显式 UTF16 保存后恢复，保留同一 NSTextStorage 和实际字节；最终专项 3/3。日志 /tmp/bailey-grid-baseline-red-20261125.log、/tmp/bailey-grid-baseline-green-20261125.log、/tmp/bailey-grid-disconnect-green-20261125.log、/tmp/bailey-grid-workspace-green-20261125.log。严格非协作 CAS 为 F-02 独立延期事项。`


## 发现 F-04

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/CSVTableView.swift:336,502,524,544; Bailey/Editor/FileViewerView.swift:891,936; Bailey/Workspace/PaneTab.swift:66`
- 摘要：`原生单格提交及粘贴的后台事务由短生命周期网格持有，网格卸载会取消已接受的编辑；尚未结束的原生字段编辑不进入文件保存及关闭保护`
- 风险：`立即切源码/切标签/保存/关闭可能丢失已输入数据，未提交字段可被干净刷新覆盖`
- 预期修复：`提交事务由 FileTab 持有；在原生编辑结束、卸载、保存、关闭与文件变更边界完成/等待该事务，保持现有源区间、版本校验与唯一 Undo，不创建第二份表格正文`
- 验证：`真实挂载 NSTextField / 系统 field editor 中文组合提交、同步拆除、粘贴与立即保存、项目真实关闭；检查原始磁盘、Undo、源/表格单一所有者及失效事务`
- 解决证据：`8488bb8a：原生字段／粘贴已接受事务迁移至 FileTab，切换、卸载、关闭、保存、改名先提交或等待；断线立即结束字段编辑，已接受内容在同一文档保留，重连写入仍校验旧版本。原始 Red 2 项／12 断言失败，断线 Red 1 项／4 断言失败，Cmd-S 与断线字段结束 Red 2 项／3 断言失败；26 项联合专项全过，最终工作区保存与实际改名、断线和编码证明 3/3 通过。真实 AppKit NSTextField/field editor、BOM/混合行尾、Unicode、唯一 Undo 和真实本机写盘；断线时序使用可控 backend，非真实连接。日志 /tmp/bailey-grid-owner-red-20261125.log、/tmp/bailey-grid-owner-green-20261125.log、/tmp/bailey-grid-disconnect-red-20261125.log、/tmp/bailey-grid-disconnect-green-20261125.log、/tmp/bailey-grid-workspace-red-20261125.log、/tmp/bailey-grid-workspace-green-20261125.log。完整 App GUI 单独延期，最新完整宿主回归进行中。`


## 发现 F-03

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/CSVPreviewUITests.swift`
- 摘要：`现有完整App CSV用例只读、排序、查找和模式路由，缺少可写网格与原生源码交错Undo/Redo及精确写盘的实际快捷键验收`
- 风险：`宿主虽证明共享TextKit和字节模型，不能证明完整App的首响应者及系统快捷键把编辑命令交给同一个文档`
- 预期修复：`在现有CSV E2E补一条真实排序后编辑、源码编辑、跨模式Undo/Redo、保存与重开；复用现有隔离测试设施`
- 验证：`实际make build:ui及独占图形会话make test:ui ONLY_TESTING=BaileyUITests/CSVPreviewUITests/testSortedGridAndSourceShareNativeUndoAndExactSave`
- 解决证据：`本机隔离 Bailey Dev 实际 testSortedGridAndSourceShareNativeUndoAndExactSave 通过（36.333s）；CSV 6/6，无跳过。真实排序、编辑、跨模式快捷键、保存和重开，非宿主替代。/tmp/bailey-seven-local-ui-e05e3732-20261125.log。`


## 发现 F-02

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Workspace/LocalWorkspaceBackend.swift:279; Bailey/Remote/RemoteCommands.swift:331-336`
- 摘要：`非协作第三方可在最终版本检查与替换之间发布新版本；本机与 Windows 已实测`
- 风险：`并发外部内容可能被静默覆盖`
- 预期修复：`必须在共享写入所有者使用经实际验证的条件原子提交，或明确批准且保留各冲突版本的替代产品契约；不新增 CSV 保存器、不重复校验冒充 CAS`
- 验证：`受控屏障注入真实外部写入；核对磁盘、双方完整字节、保存错误、原生草稿、重新打开及共享旁车路径`
- 解决证据：`尚无满足契约的实现。2026-11-25 独立真实 APFS RENAME_SWAP 与 Windows NTFS ReplaceFileW 实验各覆盖原地写／原子替换、替换后第三方再写四种时序；交换/备份虽可保留已捕获字节，却已经发布旧草稿而非原子拒绝。两平台再实测独立进程在交换前持有旧文件描述符/共享句柄：交换、核对及删除备份后，第三方写入和 flush 成功，但原路径保持 Bailey 草稿、第三方字节随旧对象关闭消失。不能把交换、事后复核或暂存备份当成任意第三方的严格 CAS。测试仅操作并清理专用临时文件；日志 /tmp/bailey-save-exchange-late-writer-20261125.log、/tmp/bailey-save-replacefile-late-writer-20261125.log。保持 Open，不降低产品契约。 补充：实际 macOS 27.3 APFS 专用临时文件上，F_SETLEASE（106）写租约，O_RDONLY/O_RDWR、预期打开数 0/1/2 均返回 EPERM；Apple XNU vfs_subr.c 的 allow_setlease 检查 com.apple.private.vfs.file-leases 私有 entitlement，vnode_setlease 拒绝未获授权进程。故不能以租约私有权限方案作为普通签名应用跨本机／SSH 的保证；保留 Open，不改内核或权限。 用户 2026-11-25 明确允许暂时阻塞平台不可实现的事项、继续其余任务。严格 CAS 延期，不降低现有版本保护，也不把此项称为已实现；待平台能力或经批准的可恢复冲突契约明确后再补验。`


## 发现 F-01

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/FileViewerView.swift:1152; Bailey/Git/DiffViewerView.swift:1150`
- 摘要：`文件或可写 Diff 的写入已提交但旧 SSH 通道失效时，丢弃待确认的保存快照，重连后仍以过期原字节版本保存；在途撤销至旧基线也可能被误判为 clean`
- 风险：`后续合法草稿无法保存；干净刷新、关闭或文件变更可能误判未确认的保存意图`
- 预期修复：`保留当前文档唯一在途文本提交快照及其版本，按当前同机连接只读核对实际已发布／原始／冲突状态；仅确认实际发布才推进基线，不重试不确定的写入，不引入 CSV 专用保存器；共用字节确认及传输错误分类`
- 验证：`真实原生网格 UTF-8 BOM 编辑→断线后成功发布→同机重连→再次编辑/保存；在途 Undo、编码转换及第三方冲突；可写 Diff 原生正文同序列，保持实际字节与所有者`
- 解决证据：`443168ca：旧实现3项Red/14失败断言；最终FileTabPersistenceTests 77/77、Diff拆分专项7/7、真实Windows CSV断线回执丢失和同机重连通过；原始UTF-8 BOM、混合行尾、中文、后续字段编辑、本机同路径隔离、在途Undo和未发布编码转换实际字节及草稿断言通过。三个Diff专项各同进程重复10轮无失败；Release、Dev严格验签通过。初轮联合测试出现Undo事件分组失败，后一次长异步用例在XCTestCore/Swift Concurrency运行时崩溃，拆分用例后复验通过，保留日志和全量复验门禁。日志 /tmp/bailey-seven-text-recovery-red-20261125.log、/tmp/bailey-seven-publication-filter-recheck-20261125.log、/tmp/bailey-seven-diff-recovery-split-20261125.log、/tmp/bailey-seven-recovery-filter-repeat-20261125.log。`


## 验证与未覆盖

- 最新本机 CSV XCTest 6/6，无跳过，覆盖跨窗命令归属、原生 Undo／Redo 与精确保存；`f2f35ff3` 实机冷重开保留末尾空记录。中文 IME、GUI 性能和第三方并发写入边界仍待核销。

- 冻结 `3f87e2e8` 完整 Host 1406/1406、无跳过，Dev 严格验签通过；不覆盖之后的保存恢复改动。
- 100001 条记录、100 次编辑与 Undo／Redo、UTF-8 BOM、混合行尾、宽 Unicode 及未改字段的原字节证据见 todo.toml；实体输入、跨窗口及真实完整 App 组合仍未验收。
- C12×C13：本机和 Windows 实测非协作第三方可在最后校验与 rename 之间写入。协作锁、RENAME_SWAP、File.Replace 都不能证明任意第三方的严格 CAS；不将其视作通过。
- 现行保存机制见 `docs/features/editor.md` 与 `docs/features/ssh.md`；27c2b254 已提交新增跨模式编辑、Undo/Redo 及实际编码字节 UI 验收，make build:ui 和 Dev 严格验签通过；未执行新增完整 App，F-03 延期；F-02 严格非协作 CAS 独立延期。

