# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：核心标注、保存与导出已有真实宿主证据；复制入口已核销；共享保存竞态和完整 App／实体设备验收仍未完成。

## 任务与改动

- **P2-T1 画布标注、光标命中和标签级撤销**：FileTab、ImageAnnotationDocument、RasterScrollView 与共用原像素坐标、原生 Undo、绘制与命中已接通（ceb3abc5）。
- **P2-T2 sidecar 条件保存、关联文件操作与像素导出**：FileTab.writeCurrentAnnotations、ImageAnnotationSidecar、ImageAnnotationDrawing 与 WorkspaceBackend；保存重开、输出 PNG/JPEG、关联文件保护与 Windows SSH 同路径隔离已接通。

## 发现项

### 画笔与工具单键（P2-T1）

隔离 Bailey Dev 打开科研图 `demo-image.png` 的副本，从真实右键菜单进入标注。修改前有九个工具、无画笔，按 R 后仍为选择；
修改后十个字母逐项命中，点矩形按钮后能直接按 P。一次拖动保存 24 个中间点；单击落点后逐次撤销、重做并保存，旁车中的笔画分别消失、原样恢复。
文字框输入 `arp` 并点「添加文字」，旁车保留原文，随后 P 重新选中画笔。按键测试未切换系统输入法。
原图 SHA-256 为 `31ca370149356115bca7222abbd1917f5ed561f2539ee53205fd561f371f5368`，始终未改。
`92b35562` 的最终 490pt 窗口中，图面宽 253.5pt，十项按钮按 8＋2 自动换行；实测全部 24×24pt 命中区在图面内，帮助含名称与字母。
窄栏点击裁剪后按 R 选中矩形。Dev、UI 测试目标及宿主测试目标均构建通过，新增 XCTest 已编译，未启动 XCTest 或实际切换中文输入法。
构建日志、原图／旁车与完整窗口截图见 `/tmp/bailey-image-keys.zhzd2N/`。上述普通 Dev 操作不冒充 XCTest、跨物理显示器或完整阶段验收。

## 发现 F-09

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageAnnotationSidecar.swift:164; Bailey/Files/FileTreeModel.swift:862,1134; Bailey/Workspace/LocalWorkspaceBackend.swift:432`
- 摘要：`用户新要求：选中已标注原图也应能同时处理其相邻标注文件，不再只允许操作整目录`
- 风险：`现有拒绝策略阻断正常原图管理；两个目录项不具备通用原子事务`
- 预期修复：`复用原有文件操作/保护/路径映射；真实原图与有效 JSON 同一逻辑操作，保护已打开的两文件，结果报告每项实际完成；任何部分失败保留可识别恢复状态，不覆盖/错删`
- 验证：`本机、实际 Windows SSH 的复制/移动/改名/删除，侧车冲突、损坏/孤立/链接、两者多选、脏稿/跨窗与部分失败、实际目标原字节及重开`
- 解决证据：`b9a34512：真实 Windows SSH 与本机 APFS 跨卷复制/移动/改名/删除，选中两项去重、目标旁车冲突拒绝、原字节、重开标注核对；FileTree/WindowOwnership 相关回归，182/182 无跳过。完整 App 实际重命名同时迁移两文件和打开标签，原图/旁车字节及图层恢复通过。两个目录项不承诺原子事务，异常报告可恢复路径，非协作 CAS 另见 F-02。`


## 发现 F-08

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageInspector.swift:493; FileViewerView.swift:1193`
- 摘要：`图片导出仅能创建新文件，无法在明确确认后使用已接受的目标版本覆盖已有图片`
- 风险：`用户无法更新已有导出文件；不能以无条件覆盖解决`
- 预期修复：`沿现有导出 Sheet 先确定目标真实版本、显式确认，再复用共享条件发布；禁止覆盖原图、其别名以及已有标注配对文件`
- 验证：`实际本机目标无覆盖、确认取消、已接受版本覆盖、确认后变更/删除/链接替换、原图及旁车不变、权限及取消；真实保存选择器`
- 解决证据：`b9a34512：本机真实已有目标、版本确认、确认后原子替换冲突、原图及硬链接、配对目标拒绝；导出取消测试通过。完整 App ImageAnnotationUITests 实际系统 Replace、应用版本确认、取消及确认发布通过（12:17:17 xcresult，99.983s）；严格第三方 CAS 另见 F-02。`


## 发现 F-07

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageInspector.swift:357-359,555-610; BaileyUITests/Editor/ImageAnnotationUITests.swift:39-49`
- 摘要：`RasterScrollView 仅声明 UndoManager，未提供标准 undo:/redo: responder 动作；既有完整 GUI 连续撤销/重做只核对最终图层，不能排除两条动作均无效`
- 风险：`可能与实际 CSV 键盘撤销失败同根；图片标注 I11 的真实键盘撤销、回到 clean 和重做缺少有效证据`
- 预期修复：`补足真实挂载原生 selector 的 Red，按实际结果在图片 viewport responder 使用同一标注文档 UndoManager；UI 检查每个动作的中间像素`
- 验证：`ImageAnnotationTests/testMountedCanvasUsesImageCoordinatesAtDifferentZoomAndNativeUndo；实际隔离完整 App 撤销像素消失、重做恢复、保存及导出原字节`
- 解决证据：`0a808796：原生画布焦点和标准撤销/重做；本机独占隔离 Bailey Dev 实际 testNativeGestureUndoSaveReopenAndCancelExportLeaveOriginalUntouched 通过（49.863s），逐次核对可见箭头消失/恢复、原字节、保存重开及导出。/tmp/bailey-seven-local-ui-e05e3732-20261125.log。`


## 发现 F-06

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageAnnotationDrawing.swift:251`
- 摘要：`滤镜采样依赖裁剪或视口外像素，当前在裁剪后的 CGContext 上钳位，导致区域预览/导出与全图合成不同`
- 风险：`模糊/马赛克边缘产生错误颜色或透明度，多个叠加滤镜误差传播`
- 预期修复：`共用原坐标和输出变换，向后查询 Core Image 所需采样区域，再按原顺序合成，最后裁剪实际输出；限定工作缓冲像素预算`
- 验证：`实际全图、区域预览、导出逐像素对照，单独及连续滤镜、不同倍率与边界；真实大图长测`
- 解决证据：`2026-11-25：原坐标采样、反向 ROI 与裁剪候选实现；独立同源像素对照 200 组、11270 次比较零误差超限，8 次 Debug 重复均通过。联合 Host 的首次 sRGB 0.17× 全图像素异常（36 个失败断言）仍待复现和归因，不关闭发现。300 次真实 6000×4000 标注 P95 4.75ms、耗时 64.58s、关闭后物理记账约 190MiB，暖机后波动 1.81MiB；PreviewScrollViewTests 26/26 全过。b1442e88 已提交；最终 ImageAnnotationTests 20/20 通过（含真实 Windows SSH），三项滤镜宿主用例各同进程连续 10 轮全部通过；Release 与 Dev 严格验签通过。当时首次异常尚未定位；冻结 443168ca 全量回归中的 testRegionalAnnotationSamplingMatchesWholeImageAcrossColorsAndZooms 已通过（3.699s），整轮最终 1411/1414、3 项跨卷独立补过。日志 /tmp/bailey-filter-combined-native-debug-20261125.log、/tmp/bailey-seven-publication-filter-green-20261125.log、/tmp/bailey-seven-publication-filter-recheck-20261125.log、/tmp/bailey-seven-recovery-filter-repeat-20261125.log。 重新读取首次失败原始日志，36 个断言前确有 IOGPUMetalError／GPU recovery 丢弃 ci_lanczosDown2_affine 指令及 CIRenderTask waitUntilCompletedAndReturnError。b38b5352 统一使用 CIRenderDestination 与可抛错任务完成边界，不接受失败产生的透明位图。实际 CIImageProcessorKernel 抛错证明旧 createCGImage 非空且不抛错，新增 XCTest Red 1/1，Green 通过并验证合法透明图及下一次成功渲染。图像 21/21、音频 5/5、300 轮大图 63.01s／P95 5.21ms，末态物理记账 114.72 MiB，原始字节／真实 Windows SSH 通过；联合 27/27，退出 0。日志 /tmp/bailey-ci-render-processor-failure-20261125.log、/tmp/bailey-ci-render-task-red-20261125.log、/tmp/bailey-ci-render-task-green-20261125.log。未主动触发系统 GPU reset，修复的是原生执行错误边界而不是驱动。`


## 发现 F-05

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageAnnotationSidecar.swift:84`
- 摘要：`SSH 旁车已经成功提交但响应丢失后保存基线不推进，后续队列对过期版本写入必然冲突`
- 风险：`实际已存草稿仍显示失败，继续编辑无法保存或关闭`
- 预期修复：`确认不确定传输后的实际旁车完整字节及原图版本，只读核对且绝不再次写入；保留确定冲突及取消错误`
- 验证：`成功写入后丢失回应，更新基线且不丢后续草稿；真实 SSH 首次创建和更新、失败/竞争保留草稿`
- 解决证据：`28311586：Red 连续保存无法推进旧版本基线；Green 真实 Windows SSH 成功创建／更新后丢回执、明确冲突拒绝、同名 Mac 文件隔离通过；断线重连、前置失败、保存中撤销、原图被替换的宿主专项通过（0.233 秒）。Release 构建及 Dev/Release 严格验签通过。日志 /tmp/bailey-seven-annotations-green-20261124.log 与 /tmp/bailey-seven-waveform-red-20261124.log。`


## 发现 F-04

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageAnnotationDrawing.swift:245`
- 摘要：`裁剪或区域预览边缘，形状几何框外实际可见描边被 hitBounds 预裁剪丢弃`
- 风险：`当前视口、复制和导出对相同原像素产生不同结果`
- 预期修复：`让 Core Graphics 实际裁剪矢量路径；滤镜保留自身 ROI 计算，不以交互命中框代替像素覆盖范围`
- 验证：`全图、区域预览及 PNG 裁剪输出逐像素对照矩形和椭圆的框外描边`
- 解决证据：`28311586：Red 实际区域预览和裁剪 PNG 的矩形／椭圆描边对照 12 项断言失败；删除 hitBounds 预裁剪后同一真实像素用例通过；18 项 ImageAnnotationTests 全部通过。日志 /tmp/bailey-seven-annotations-red-20261124.log 与 /tmp/bailey-seven-annotations-green-20261124.log。`


## 发现 F-03

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageInspector.swift:337`
- 摘要：`需求中的图片复制尚无入口，只有标注导出`
- 风险：`用户无法将当前标注的合成图直接复制；不应另建截图或渲染实现`
- 预期修复：`在现有原生图片右键和 AX 中提供复制，复用当前草稿版本的 PNG 输出及已有剪贴板发布模式`
- 验证：`命名剪贴板实际 PNG 字节及图层/crop 像素；取消/过期请求不改剪贴板，原图和旁车不变；原生菜单/AX`
- 解决证据：`72006d6b：原生菜单及 AX 用例先 Red；新增复制当前草稿入口后 18/18 相关宿主通过，含真实 Windows SSH、裁剪 PNG 字节与像素、命名剪贴板、过期请求/取消保留原剪贴板，底图及 JSON 不变。Debug 和 Dev 严格验签通过。日志 /tmp/bailey-seven-copy-green-20261124.log。`


## 发现 F-02

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Workspace/LocalWorkspaceBackend.swift:279`
- 摘要：`本机和 Windows SSH 最终 SHA 校验到 rename 之间的非协作写入能被静默覆盖`
- 风险：`外部最新版本可能丢失；Bailey 自身的协作锁不足以实现任意写入者的 CAS`
- 预期修复：`在共享 Backend 确认可行的原子条件提交或保留可恢复冲突版本的设计；不得用重复校验或上层重试冒充原子性`
- 验证：`实际本机及 Windows SSH 在最终检查与提交间的受控外部写入；底图/旁车与 CSV 都保留冲突数据`
- 解决证据：`尚无满足契约的实现。2026-11-25 独立真实 APFS RENAME_SWAP 与 Windows NTFS ReplaceFileW 实验各覆盖原地写／原子替换、替换后第三方再写四种时序；交换/备份虽可保留已捕获字节，却已经发布旧草稿而非原子拒绝。两平台再实测独立进程在交换前持有旧文件描述符/共享句柄：交换、核对及删除备份后，第三方写入和 flush 成功，但原路径保持 Bailey 草稿、第三方字节随旧对象关闭消失。不能把交换、事后复核或暂存备份当成任意第三方的严格 CAS。测试仅操作并清理专用临时文件；日志 /tmp/bailey-save-exchange-late-writer-20261125.log、/tmp/bailey-save-replacefile-late-writer-20261125.log。保持 Open，不降低产品契约。 补充：实际 macOS 27.3 APFS 专用临时文件上，F_SETLEASE（106）写租约，O_RDONLY/O_RDWR、预期打开数 0/1/2 均返回 EPERM；Apple XNU vfs_subr.c 的 allow_setlease 检查 com.apple.private.vfs.file-leases 私有 entitlement，vnode_setlease 拒绝未获授权进程。故不能以租约私有权限方案作为普通签名应用跨本机／SSH 的保证；保留 Open，不改内核或权限。 用户 2026-11-25 明确允许暂时阻塞平台不可实现的事项、继续其余任务。严格 CAS 延期，不降低现有版本保护，也不把此项称为已实现；待平台能力或经批准的可恢复冲突契约明确后再补验。`


## 发现 F-01

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageAnnotationDrawing.swift:240`
- 摘要：`每次滤镜渲染新建 CIContext；百次真实大图标注关闭后的 RSS 从 176.3 增至 897.6 MiB，后半段继续增长`
- 风险：`频繁缩放/修改与导出重建 GPU/CPU 资源缓存，增加交互成本及内存；弱引用释放不等于实际资源回收`
- 预期修复：`按 Apple CIContext 的不可变线程安全语义复用同一渲染器的上下文，保持每次实际滤镜与图像数据独立；以相同真实长测确认收益`
- 验证：`PreviewScrollViewTests.testHundredFilteredAnnotationSessionsRetireDecodedPixels 同环境 A/B、实际滤镜像素及不同色彩/并发输出`
- 解决证据：`bdd4c12b：同一百次真实大图区域压力测试，滤镜 P95 42.292→2.856ms，CPU 22.81→20.65s，峰值 RSS1123→1053.69MiB，RSS 初始/结束 153.16/828.53MiB，原对象均释放；12对并行不同输出实际像素/ICC 与图层顺序测试通过，3/3、0跳过、make build 及 Dev/Debug 严格验签通过。残余 RSS 缓慢增长仍待调查，不冒称内存完全收敛。日志 /tmp/bailey-seven-shared-filter-context-20261124.log`


## 验证与未覆盖

- 最新本机隔离 App：键盘撤销／重做、保存、重新打开、复制和确认覆盖导出通过；`92b35562` 的十个单键、真实画笔轨迹与窄窗换行另有真实 App 操作证据。仍需中文 IME、物理设备及严格非协作写入边界验证。

- d52ba2b3：同机独立 ImageIO／Core Image 6组×80次证实无活跃对象时 RSS 可保留大量可回收页。真实 6000×4000 标注300轮开闭 66.10 秒、滤镜 P95 6.26 ms；每轮 FileTab／标注文档／图像对象弱引用全部释放，RSS 248.31→985.56 MiB、峰值1210.72 MiB；实际物理记账82.31→99.80 MiB，暖机至末段最大差5.42 MiB。日志 `/tmp/bailey-image-memory-native-20261124.log`、`/tmp/bailey-seven-annotations-green-20261124.log`。不宣称完整 App、任意时长或所有设备无泄漏。
- 冻结72006d6b完整回归1403/1404通过；唯一Windows Rebase前置建目录25秒超时，同项原阈值独立复验通过（30.235秒）。新标注专项18/18及新增时序单项均通过；本轮新代码未重新完成全量测试。

- 定点 15/15，补充标注专项 7/7，make test 退出 0；UI Target 构建及 Dev 严格验签成功。日志 `/tmp/bailey-seven-current-focused-20261124.log`、`/tmp/bailey-seven-annotation-extra-20261124.log`。
- b0ccce58：八种 EXIF 取向、中文／emoji 字形实际像素、保存期间编辑、原生关闭失败否决、只读目录及取消、真实 Files 关联保护、百次大图滤镜全部通过。100 次 RSS 176.3→897.6 MiB、峰值 1123 MiB；bdd4c12b 已优化同一测试 P95 至 2.856ms，仍有残余 RSS 增长。
- 非协作外部进程的检查／发布间竞态已复现；实体 1×、触控板、VoiceOver 及独占完整 App 尚缺环境，不能以宿主动作代替。I13 和 I10/I11/I16 的相关交叉验收未核销。
- 当前行为见 docs/features/editor.md 图片标注与导出；72006d6b 新增原生复制当前标注合成图；文档同步。
- 本轮完整 App 用例补充真实原生复制菜单与 NSSavePanel 成功导出，解码 PNG 核对尺寸、标注像素、底图及旁车原字节；共用系统选择器路径验证。45534516603（4575cddb）实际通过该复制/导出用例；原撤销及重做连续执行仅断言最终图层，缺少中间状态证明，另见 F-07。

- 2026-11-25 F-02 部分缓解（`bd6e74a2`）：实际独立进程两种提交时序的旁车完整字节、底图不变、dirty、错误路径、旧基线重试拒绝及恢复后显式保存均经宿主断言通过；5 项定点联合命令零失败零跳过。仍不满足非协作严格 CAS，详见 [CSV P2 F-02](../csv-table-view/audit-p2.md)。恢复提示的实际窄窗可读性、实体输入及长会话未执行，阶段 No-Go。

- 5d216abe：图像旁车共用恢复错误，真实两种外部发布与失败重试后保留原图、双方图层及准确恢复地址。宿主通过，严格 CAS 和实体/完整 App 门禁不变。 共享验证证据见 [CSV P2 F-09](../csv-table-view/audit-p2.md#发现-f-09)。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；[共享 P1 审计](../file-viewer-routing/audit-p1.md) 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 实际隔离 Dev 标注中文 IME 试验到达文字编辑器，但期间有其他桌面输入，产生额外非试验图层；本轮数据不可用于验收。仅修改隔离夹具，已核对原始 PNG 与副本底图字节一致、退出隔离 Dev、恢复原输入源。证据 `/tmp/bailey-ime-native.VZLk2z/`；不据此增加产品缺陷，文字输入仍待独占图形复验。
