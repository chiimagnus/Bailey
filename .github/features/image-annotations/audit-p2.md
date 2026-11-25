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

- d52ba2b3：同机独立 ImageIO／Core Image 6组×80次证实无活跃对象时 RSS 可保留大量可回收页。真实 6000×4000 标注300轮开闭 66.10 秒、滤镜 P95 6.26 ms；每轮 FileTab／标注文档／图像对象弱引用全部释放，RSS 248.31→985.56 MiB、峰值1210.72 MiB；实际物理记账82.31→99.80 MiB，暖机至末段最大差5.42 MiB。日志 `/tmp/bailey-image-memory-native-20261124.log`、`/tmp/bailey-seven-annotations-green-20261124.log`。不宣称完整 App、任意时长或所有设备无泄漏。
- 冻结72006d6b完整回归1403/1404通过；唯一Windows Rebase前置建目录25秒超时，同项原阈值独立复验通过（30.235秒）。新标注专项18/18及新增时序单项均通过；本轮新代码未重新完成全量测试。

- 定点 15/15，补充标注专项 7/7，make test 退出 0；UI Target 构建及 Dev 严格验签成功。日志 `/tmp/bailey-seven-current-focused-20261124.log`、`/tmp/bailey-seven-annotation-extra-20261124.log`。
- b0ccce58：八种 EXIF 取向、中文／emoji 字形实际像素、保存期间编辑、原生关闭失败否决、只读目录及取消、真实 Files 关联保护、百次大图滤镜全部通过。100 次 RSS 176.3→897.6 MiB、峰值 1123 MiB；bdd4c12b 已优化同一测试 P95 至 2.856ms，仍有残余 RSS 增长。
- 非协作外部进程的检查／发布间竞态已复现；实体 1×、触控板、VoiceOver 及独占完整 App 尚缺环境，不能以宿主动作代替。I13 和 I10/I11/I16 的相关交叉验收未核销。
- 当前行为见 docs/features/editor.md 图片标注与导出；72006d6b 新增原生复制当前标注合成图；文档同步。
- 本轮完整 App 用例补充真实原生复制菜单与 NSSavePanel 成功导出，解码 PNG 核对尺寸、标注像素、底图及旁车原字节；共用系统选择器路径验证。Swift 6 typecheck 已通过，独占 GUI 尚未实测。

