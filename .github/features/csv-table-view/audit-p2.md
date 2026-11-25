# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：共享文档、原生编辑、编码、Undo、断线与条件保存已通过宿主和实际完整 App；双窗真实冲突及十万行 GUI 编辑保存通过。真实拼音提交暴露连续快捷键焦点缺陷 F-10（已修复且宿主回归通过，待完整 App 连续快捷键复验）；e471b25b 已完成共享 VS Code 式保存冲突本机实施及实机验收；真实 Tailscale SSH CSV 比较、版本绑定覆盖及重连已通过；严格非协作 CAS 边界、P1 无障碍及现有设备门禁独立保留。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；可执行项仍需验收。
  保存冲突统一按[VS Code 保存冲突方案](../file-viewer-routing/plan-p1.md#shared-save-conflicts)，不将严格 CAS 冒称已解决。

## 任务与改动

- **P2-T1 对原文源区间执行原生编辑、复用唯一 Undo**：FileTab、原生表格与 TextKit 共用文档和 Undo；100001 条记录、100 次编辑／切换和 Undo／Redo 有宿主证据，实际中文 IME 提交及十万行 GUI 编辑已验，807fbdee 的连续快捷键仍待完整 App 复验。
- **P2-T2 严格往返编码、条件保存和外部冲突**：FileTab、DiffTab、TextFileEncoding、WorkspaceFileVersion 共用原字节版本和提交确认；重连保留在途快照，不盲目重复写入；e471b25b 共用只读原生 Diff 和一次性版本绑定覆盖，未改变条件发布后端。

## 发现项

## 发现 F-11

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/FileViewerView.swift:1251; Bailey/Git/DiffViewerView.swift:1144; Bailey/UI/Components/WorkspaceChrome.swift:196`
- 摘要：`已检测外部冲突但仅显示错误文本，用户无法在同一未保存文档中比较并确认当前磁盘版本`
- 风险：`被迫借助外部工具恢复旧文件或关闭草稿；简单强制覆盖会绕过已接受版本及目标保护`
- 预期修复：`共享冲突快照、现有只读原生 Diff、一次性版本与草稿绑定的显式覆盖；继续走原保存队列和有条件写入，复用旁车保护`
- 验证：`FileTabPersistenceTests、NativeDiffTabTests、ImageAnnotationTests，真实本机双窗口及获授权 SSH，比较/取消/确认/过期版本与草稿/恢复原字节`
- 解决证据：`e471b25b：共享冲突快照绑定文档、目标代次、路径、原基线、磁盘与草稿 SHA-256；原生 Diff 比较/取消/显式条件覆盖、比较过期拒绝、编码意图、保存中继续编辑、独立进程迟到写入恢复、Git index/HEAD、图片旁车与底图已验。最终新增宿主8/8，真实 GUI 2/2，均零跳过；受影响宿主回归127通过、2项图像样本配置跳过、0失败；最终 make build 和严格验签通过。日志 /tmp/bailey-save-conflict-final-test.SPReHd、/tmp/bailey-save-conflict-final-ui.n6xMZo、/tmp/bailey-save-conflict-regress.1nc20Y、/tmp/bailey-save-conflict-final-build.STnTDk。本机验收后，e697efb5 补充两条独立真实 Windows Tailscale SSH 通道：同长度同 mtime 的独立改写、只读比较、旧磁盘确认及旧连接确认拒绝、重新确认后保存、BOM／混合换行与本机同名文件不变，44.056 秒通过；既有 CSV 丢回执与重连用例 29.949 秒通过。日志 /tmp/bailey-tailscale-reviewed.F3CYF2、/tmp/bailey-tailscale-routing.DnjOhC。两轮其余用例另有失败或中断，不冒称整轮通过；F-02 严格非协作 CAS Deferred 不变。`


## 发现 F-10

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`CSVTableView.surface; NativeDelimitedGrid; DelimitedGrid.control`
- 摘要：`真实中文候选提交后表格因新解析代次卸载，原生首响应者丢失；撤销后重做亦需重新点击`
- 风险：`连续原生快捷键与导航失效，真实表格编辑流程被打断`
- 预期修复：`保持同一原生表格，失效时仅清除数据投影；键盘显式提交归还表格焦点，普通失焦不抢焦点`
- 验证：`真实 SwiftUI/AppKit 挂载 Red/Green；原生标记输入、Return/Tab/Shift-Tab、取消、失焦、连续 Undo/Redo、保存及完整 App 快捷键`
- 解决证据：`807fbdee：真实 SwiftUI/AppKit 挂载，Red 2 条（表格更换、首响应者丢失）；Green 保持同一原生表格，标记文字确认、Return/Tab/Shift-Tab、取消、失焦、连续 Undo/Redo、其他输入框焦点和空表清除/恢复均核对实际对象、文档和磁盘。受影响宿主 154/154，零失败零跳过；追加空表与键盘导航最终定点 1/1（0.838s）；正式 Debug、UI Target 构建、Dev/Debug 严格验签通过。日志 /tmp/bailey-grid-focus-regress.opOyf6、/tmp/bailey-grid-final.QxPIeA。已删除完整 App 用例中用于重新获焦的额外点击，尚待执行该版实际快捷键；不冒称完整 GUI 验收。`


## 发现 F-09

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`FileViewerView.swift; DiffViewerView.swift`
- 摘要：`共享条件保存冲突恢复路径在重复保存失败后被普通错误覆盖，单行提示可截断实际恢复地址。`
- 风险：`用户无法找到已保留的第三方版本，降低冲突恢复能力。`
- 预期修复：`保留结构化恢复错误直到保存成功；共享可阅读、可复制的错误提示。`
- 验证：`CSV、旁车、Diff 三入口真实独立进程竞态、重试和恢复，窄窗提示布局。`
- 解决证据：`5d216abe：三入口真子进程原位写及原子替换，重试路径 Red 6 断言，Green 8/8；CSV 两次竞态保留两个位置及两份原始版本，扩大宿主 16/16、零跳过。实际 SwiftUI 原生宿主 920/480/220 点、中英文深浅 12 组尺寸全通过；不等于 VoiceOver 或完整 App GUI。正式 Debug 与 Dev 严格验签通过。日志 /tmp/bailey-recovery-notice-red.Zda2K5f3、/tmp/bailey-recovery-notice-green.yDck3vps、/tmp/bailey-recovery-notice-expanded.ttYRLK1Q、/tmp/bailey-recovery-notice-build.Hklrh1XN。严格 CAS 仍归 F-02。`


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

- 2026-11-25 F-02 部分缓解（`bd6e74a2`）：独立子进程在最终校验后原位写入／原子替换，原实现 2 项测试 12 条断言失败；APFS 交换后验证被替换入口，冲突保留完整外部版本及恢复路径，目标可能已是本地草稿，保留 dirty 且旧基线重试被拒，恢复基线后显式重试可保存。不自动回滚覆盖后续写入。定点 5/5、零跳过；日志 `/tmp/bailey-late-publication-red.jDU5Is3V`、`/tmp/bailey-late-publication-green-v2.5gJvMfiG`、`/tmp/bailey-save-recovery-build.S9RL3c5U`。独立进程仍可通过旧文件描述符在核对及清理后写入已解除链接的 inode，SSH 非协作边界也未改变；F-02 继续 Deferred，不称严格 CAS。不支持交换的文件系统拒绝覆盖；独立 exFAT 镜像创建被系统拒绝，未实测该文件系统，未修改权限。恢复路径已验证模型错误字符串，窄窗单行错误栏完整可见性未验，真实 IME／跨窗长会话继续 blocked。

- 5d216abe：三入口真实竞态、两次冲突恢复位置跨重试保留、窄窗错误提示和 16 项相关宿主通过；F-09 已解决。严格 CAS 和完整 App/实体门禁不变。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；[共享 P1 审计](../file-viewer-routing/audit-p1.md) 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 87655cad：隔离完整 App 真实双窗口同一文件；独立 XCTest 进程原子改写，旧窗口保存拒绝且草稿保留，第二窗保存新版本，旧窗重试仍拒绝；显式恢复基线后旧稿保存及最终字节校验通过（41.068秒）。此为真实预检查冲突与恢复，不替代严格非协作 CAS。 日志 `/tmp/bailey-preview-remaining.ukxYU4`。本批另有十万行 AX 查询和视频采样失败、三项键盘权限跳过；不宣称本批全部通过。

- `8800266d`：真实 6,634,189 字节十万行 CSV，打开、查找唯一末行、编辑 `100000`→`100001`、显式保存；其余字节及原样本一致。单项 63.726 秒通过，无跳过；日志 `/tmp/bailey-preview-retry2.9NmlJE`。该耗时含 XCTest AX 查询，非纯产品延迟；C14 宿主 P95 见原证据。
- 真实中文拼音在隔离 Dev 单元格内组合并确认，候选期间磁盘保持 BOM／混合 CRLF 与 LF 原字节，最终中文、撤销／重做及保存字节一致；但提交和撤销后必须重新点击表格才可继续快捷键，由此新增 F-10。日志 `/tmp/bailey-ime-native.VZLk2z/{04,05,06,07,08,10,11,12}.json`。XCTest 注入原生物理键受权限限制，改用获授权实际输入法；不计其基础设施跳过为产品通过。
