# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：读取、资源、媒体与模式归属的共享实现已接入七格式，实际跨格式数据和生命周期回归通过；完整设备／GUI 矩阵尚未核销。

## 任务与改动

- **P1-T1 核销读取与公共资源边界，移除新格式产生的重复路径**：FileTab.readContent、NativeMedia.open、PreviewResource、LocalPathScope、RasterPreview、SVGArtwork 共用原文件／资源版本校验及安全边界；Windows SSH 与本机实际目标隔离，媒体不整读或跨机器降级。
- **P1-T2 让下一种预览复用同一展示模式、Dock 和系统菜单**：FilePreviewMode、DockItem.filePreview、Project、FileViewerView、系统 File 菜单及 TabContentThumbnail 已统一；CSV、SVG、HTML 与 Markdown 共用源码／预览／并排所有权。提交 49a9e09d、24019b00。

## 发现项

## 发现 F-06

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Resources/Info.plist:35-69`
- 摘要：`系统混合文件投递缺少音频和视频 UTI 注册`
- 风险：`Finder、LaunchServices 无法向 Bailey 投递音视频，七格式系统投递直接失败`
- 预期修复：`注册 public.audio/public.movie 为 Viewer，继续使用 Alternate/None rank；不扩大未知数据类型`
- 验证：`AppIdentityTests Red→Green；真实七格式混合 NSWorkspace.open 和双窗恢复`
- 解决证据：`8613305c：AppIdentity 20/20，音频/视频使用 Viewer 和现有 rank；原混合 NSWorkspace 投递 kLSAppDoesNotClaimTypeErr，修复后真实七格式投递成功、七个标签存在且可进入切换验证（12:17:17 xcresult）。完整双窗冷恢复仍独立核销，不以此替代 F-04。`


## 发现 F-05

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Remote/GitInteractiveRebaseIntegrationTests.swift:127-146`
- 摘要：`完整宿主两次在实际 Windows SSH 交互式 Rebase 准备阶段约25秒失败，记录的是清理不存在的本地终端历史文件错误而非明确的SSH阶段`
- 风险：`阻塞最终全量验收；无法判断远端初始握手、命令超时或真实错误传播。创建失败时原夹具尚未登记清理；返回路径只检查前缀而非完整字符集。`
- 预期修复：`在实际远端准备阶段明确诊断错误；仅在真正变更本地工作区前保存并恢复快照；远端夹具使用本地生成的随机专属路径、精确清理自己的目录和连接，不扩大时限、不吞原始错误。`
- 验证：`原失败日志；定点真实 Windows SSH 交互式 Rebase、错误恢复、相关 SessionStore 和完整宿主回归。`
- 解决证据：`524db207：真实 Windows SSH Rebase 定点 3/3、SessionStore 11/11；05696bb5 冻结版完整 make test 1366/1366，0失败0跳过，耗时2007.208秒，Debug/Release/UI target构建与严格签名通过。`


## 发现 F-04

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/CSVPreviewUITests.swift:85`
- 摘要：`完整 App 缺少七种真实复杂格式在双窗口内交叉切换、系统重新投递和正常 Quit 冷恢复的组合回归`
- 风险：`各格式单独 GUI 和百次宿主切换不能证明跨进程系统菜单、窗口目标、实际 Dock 与会话恢复的集成行为`
- 预期修复：`补一条独立 Dev 完整 App E2E，使用真实综合样本、同名文件双窗及系统文件投递，逐格式检查实际预览、媒体位置及源字节；正常退出重启验证所有文件标签默认模式和归属`
- 验证：`make build:ui；独占图形会话中 make test:ui ONLY_TESTING=BaileyUITests/FilePreviewWorkspaceUITests`
- 解决证据：`aad56a6b：完整 App 用唯一窗口 ID 核验同名 CSV 归属。Mac Apple Development 签名 Bailey Dev 以真实七格式样本运行，通过系统投递、双窗多轮切换、视频位置、HTML 并排、正常退出冷启动及全部源字节校验。1 项通过 0 跳过，279.037 s。日志 /private/tmp/bailey-xc-recheck.hgaWdv/focused.log。`


## 发现 F-03

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Git/GitPanelVisibilityTests.swift:497`
- 摘要：`全量宿主回归中密集 Git Graph 的原生 AXPress 后展开断言失败`
- 风险：`无法确认共享工作区滚动与密集提交控件在长会话仍可操作`
- 预期修复：`检查实际 AXPress 与模型更新的时序，区分测试宿主异步交付和真实产品行为；保留展开、收起与大 Changes 后交互断言`
- 验证：`密集 Graph 48 组合、真实 Git DAG、120pt 窄布局、1026 Changes 和实际 AXPress；定点与全量回归`
- 解决证据：`1c4f2eff：原 3 项 GitPanelVisibilityTests 定点全部通过；本次完整宿主回归中密集图谱 48 组合、120pt、1026 Changes、真实 AXPress 用例再次通过（13.897s），另外两个同类用例也通过。原始日志 /tmp/bailey-seven-20261124-full-after-1c4f2eff.log。全量另有 SSH 交互式 Rebase 失败，不能称整个回归已绿。`


## 发现 F-02

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:544-551`
- 摘要：`FSEvents 监听范围替换只刷新已缓存目录，不能保证 Quick Open 索引失效`
- 风险：`外部 linked worktree 的 Git index 或折叠子树仅在订阅空窗变更时，原目录内容可保持不变，导致文件打开入口继续使用旧索引`
- 预期修复：`让监听范围替换与 FSEvents 丢失事件走同一全量对账及索引版本失效路径，保留真实订阅事件的独立断言`
- 验证：`实际 linked worktree 外部 index 在尚未订阅时变化，验证扩展监听后原目录行不变但索引更新；单独验证已经覆盖的原生 index 与共享 exclude 事件`
- 解决证据：`ffc436c3：独立 FSEvents 观察者确认真实外部 index 事件在扩展订阅前已送达，旧实现定点失败，修复后不改变 Files 行即更新 contentRevision，实际 Git 查询包含暂存文件；已有原生外部 index 及共享 exclude 独立通过。两组126项，122通过、4环境跳过、0失败，make test 退出0，Debug/Dev 严格验签通过。日志 /tmp/bailey-seven-20261124-watcher-gap-red.log、/tmp/bailey-seven-20261124-watcher-green.log。`


## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Workspace/NativePaneRetentionIntegrationTests.swift:924`
- 摘要：`完整宿主长会话中 Markdown 媒体 AX 按钮触发失败`
- 风险：`共享媒体的独立播放器和私有暂存生命周期验收中断`
- 预期修复：`将同进程 AXUIElement 查询与 press 移至后台，允许主线程服务真实 AX 请求，保留窗口归属与真实按钮断言`
- 验证：`记录全量失败；同一实际样本重跑原生生命周期与同进程 AX 邻近组合，核对独立播放器和暂存释放`
- 解决证据：`af6c1c90：全量 1362 项执行，1361 通过、1 失败、0 跳过；定位到窗口 32×112、Markdown 视口 30 点宽，窗口容器持有实际 1080×560 后真实 AX 按钮通过，四样本独立播放器与暂存释放原断言全部保留。定点 Red→Green，三类 61/61 通过、0 跳过，Dev 严格验签；日志 /tmp/bailey-seven-features-full-20261124-1638.log、/tmp/bailey-media-ax-tree-20261124.log、/tmp/bailey-media-ax-contained-20261124.log、/tmp/bailey-seven-features-ax-final-20261124.log。`


## 验证与未覆盖

- 最新验收：真实七格式的双窗归属、系统重新投递、正常退出与冷启动、关闭标签及源字节检查通过（`aad56a6b`、`2edc31c1`）。物理设备及完整 App 长会话和全部交叉组合仍未核销。

- 2026-11-25：XCTest 授权后，`92b35562` 七格式综合实际通过系统投递、切换、视频定位和 HTML 并排，正常退出后双窗已出现，但索引查询把两个文件所有者读成同一窗口 ID。读取本次隔离会话的持久化快照确认 primary 七个标签、secondary 两个标签分属两个窗口。F-04 尚未核销；需使用稳定窗口查询验证每个窗口的实际标签。不把快照正确等同于 GUI 通过。Red 日志：`/private/tmp/bailey-xc-recheck.hgaWdv/matrix.log`。

- 2026-11-25：针对现有七格式阶段补验本机可执行场景。`f2f35ff3` 在隔离 Dev 清空并保存 CSV 末格，冷启动仍有空行；`b029b857` 在双窗口经 Launch Services 重新投递，取回原窗口及原视频 4.013 秒画面，继续播放正常。`839186db` 通过实际文件模型、TextKit 和 WKWebView 的编辑后滚动与重挂验证。`92b35562` 在隔离 Dev 验证图像标注工具键位、文字焦点、窄栏、保存和原图保护。此轮宿主／UI 目标成功构建，但未执行 XCTest，也未重跑完整七格式双窗冷启动链；F‑04 仍延期，不以分项结果代替。

- 2026-11-25 11:24：新增本地提交 `9b62d36c`、`0a808796`、`e05e3732`。真实CSV编码发布竞态、CSV标准原生Undo/Redo与图片画布焦点/撤销已Red→Green，另修正音频GUI鼠标拖拽测试。最终专项4/4、受影响宿主243/243、零失败零跳过（429.771秒），含真实Windows CSV/旁车、栅格和科研SVG百次、300次滤镜、120秒GIF、工作区及输入法。结果包 `Test-Bailey-2026.11.25_11-14-05-+0800.xcresult`；`make build:ui`、`make build:release` 和Dev/Release严格验签均退出0，Release 57 MiB。日志 `/tmp/bailey-seven-native-undo-and-encoding-green-v2-20261125.log`、`/tmp/bailey-seven-undo-affected-20261125.log`、`/tmp/bailey-seven-native-undo-ui-build-20261125.log`、`/tmp/bailey-seven-native-undo-release-20261125.log`。这是前版完整1422项之后的受影响验证，不冒称新提交再次完成全量或完整GUI。新提交未推送；本机用户使用桌面，完整GUI/实体设备及非协作CAS仍按已批准延期。

- 2026-11-25 10:39–10:54：`4575cddb`（产品代码与 `8488bb8a` 一致）[隔离 GUI 验收 45534516603](https://github.com/chiimagnus/Bailey/actions/runs/45534516603)，真实 macOS 27.0.1／Xcode 27.2，25 项：20 通过、2 失败、3 缺少综合样本环境而跳过。HTML 3/3、SVG 6/6、图像标注 1/1（原 Undo/Redo 中间像素未断言）、栅格 2/2、CSV 5/6、媒体 3/4；七格式双窗、真实 GIF 与字幕样本未执行。音量 F-01 已核销；CSV 键盘焦点真实 AX 菜单禁用、波形拖动误用触摸事件均有 xcresult 证据，分别见 CSV P2 F-07、音频 P2 F-02。图像标注同类撤销覆盖缺口见图片 P2 F-07；CSV 并发编码 F-06 另有待复现用例。日志及结果包 `/tmp/bailey-gui-45534516603.h0OonZ`。不以通过的单格式 GUI 替代缺失的组合与实体设备。

- 2026-11-25 冻结 `8488bb8a`：新增六项宿主用例后完整 `make test` 1422/1422 通过、0 失败、0 跳过，2671.638 秒；真实 Windows SSH、实际样本、独立 APFS 跨卷均执行。xcresult `.build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.25_10-23-08-+0800.xcresult` 复核一致。`BAILEY_TEST_EXIT=0`、`DEV_STRICT_SIGNATURE=0`、`APFS_DETACH_EXIT=0`，独立卷和标记已清理；外层 `FINAL_EXIT=1` 由于运行期间 HEAD 更新为纯计划文档提交 `4575cddb`，已核对两个提交的产品、测试、项目配置完全相同；运行中新增的下一轮测试未参与该次构建，不混入结果。UI Test Target、Release 构建与严格签名均通过，57 MiB。构建日志 `/tmp/bailey-seven-build-8488bb8a-20261125.log`，全量日志 `/tmp/bailey-seven-full-8488bb8a-20261125.log`。七份计划的完整 App 与物理环境门禁仍保留，新增 F-06/F-07 待核销。

- 2026-11-25 用户明确决定：暂时无法完成的条件（非协作第三方严格 CAS、当前不具备的独占 GUI／实体设备条件）保留 blocked，其他独立实现、审查和可执行验证继续推进。已执行测试与延期条件分别记录，不以延期冒充通过或擅自修改保存契约。当前只有用户正在使用的图形会话，不抢占；尚未推送本地三个提交，远端旧版结果不替代新版 GUI。
- 冻结 `27c2b2548ac3753c71bc211ecdabdc2bf4421e46` 全量回归最终 1416/1416 通过、0 失败、0 跳过，2134.756 秒，`make test`、Dev 严格签名、隔离 APFS 卸载及完整命令退出均为 0。真实 Windows SSH、实际样本及独立跨卷测试均执行；源码版本开始与结束一致。日志 `/tmp/bailey-seven-full-27c2b254-20261125.log`，结果包 `.build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.25_03-17-08-+0800.xcresult`。不覆盖本轮后续源码改动。

- 2026-11-25：bd72f327 修复波形原生 AX，b38b5352 修复 Core Image 执行错误，27c2b254 增补四格式实际编辑和复制／导出 UI。图像标注 21、音频计时 5、真实 300 轮大图 1，联合 27/27、0 失败、0 跳过、退出 0；make build:ui 与 Dev 严格签名、make build:release 与精简后 Release 严格签名全部通过（57 MiB）。日志 `/tmp/bailey-ci-render-task-green-20261125.log`、`/tmp/bailey-seven-ui-b38b5352-20261125.log`、`/tmp/bailey-seven-release-b38b5352-20261125.log`。冻结 `27c2b254` 最新全量已于 03:17:05 启动，实际 Windows SSH、真实样本及隔离 APFS 跨卷已配置；日志 `/tmp/bailey-seven-full-27c2b254-20261125.log`。截至本条记录尚未结束，不据此声称通过。新增 UI 只构建未执行，三次本地提交未推送。

- 2026-11-25：远端 `6102bf3e`（生产源码同 `443168ca`）[Actions 45448818282](https://github.com/chiimagnus/Bailey/actions/runs/45448818282) 实际完整 App 隔离 GUI 20 项：18 通过、2 音频失败、0 跳过（549 秒）；CSV 5/5、HTML 3/3、图像标注 1/1、栅格 2/2、SVG 5/5、媒体 2/4。两项失败从真实 xcresult 及录像定位，音频修复见 bd72f327 与音频 P1/P2 审计。新增七格式综合/编辑/复制导出用例未推送且未执行。冻结 `443168ca` 宿主完整 1414 项：1411 通过、3 跨卷跳过、0 失败（2144.031s）；隔离 APFS 三项单独全部通过、退出 0、镜像已卸载。按用例身份合计 1414/1414，不伪称单次全量无跳过。日志 `/tmp/bailey-seven-full-443168ca-20261125.log`、`/tmp/bailey-seven-final-cross-volume-20261125.log`、`/tmp/bailey-seven-cloud-ui-6102bf3e-20261125.log`。这不覆盖后续 bd72f327、b38b5352 的新代码。

- 2026-11-25：冻结提交 `3f87e2e8` 的完整宿主 XCTest 与 xcresult 一致，1406/1406 通过、0 失败、0 跳过，宿主耗时 2171.755 秒；`** TEST SUCCEEDED **`，Dev 严格签名复核通过。真实 Windows SSH、隔离 APFS 跨卷、真实图像与媒体样本均执行。结果包 `.build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.25_00-15-20-+0800.xcresult`，日志 `/tmp/bailey-seven-full-3f87e2e8-20261125.log`。此证据不覆盖之后提交的 b1442e88、443168ca，设备及完整 GUI 仍为 No-Go。

- 本轮产品 Debug/Release 构建与严格签名、补测7/7后的 `make build:ui` 与 Dev 严格签名均通过；日志 `/tmp/bailey-seven-final-debug-20261124.log`、`/tmp/bailey-seven-final-release-20261124.log`、`/tmp/bailey-seven-p2-final-ui-build-20261124.log`。新增七种完整App双窗口/退出重开用例及GIF系统设置尊重用例已构建，当前机器无独占图形验收会话，实际UI未执行。

- 整合冻结源码与 `ceb3abc5` 产品源码逐文件核验一致；完整宿主 1391/1393 通过、2 个失败用例（3 个断言）、0 跳过，2111.098 秒。失败：Git 标签包含关系查询与独立状态刷新竞争；PanelContext 延迟重命名夹具误报不存在的 sidecar 为存在。两处测试夹具修正后最终 GitTagActionTests/PanelContextTests 30/30、0失败、0跳过（日志 `/tmp/bailey-seven-final-fixture-recheck-20261124.log`）；另补充真实标注7/7及十万行CSV百次编辑1/1通过。未在最后测试夹具提交后重跑完整全量，不以此前失败全量或单独补测代替 Go。日志 `/tmp/bailey-seven-20261124-p2-integrated-full.log`。真实 Windows SSH、100 次栅格/复杂 SVG、120 秒 GIF 长会话、跨卷均执行。

- 冻结提交 `b54ee4cf`：完整宿主 1379/1379、0 失败、0 跳过，耗时 2069.626 秒；真实 Windows SSH、真实样本、GIF 长会话、独立 APFS 跨卷均启用，Dev 严格签名通过。日志 `/tmp/bailey-seven-20261124-p2-checkpoint-full.log`。这是加入新标注、HTML 运行及媒体 P2 退役改动前的基线，不代替整合后的回归。

- 05696bb5 冻结版完整 `make test`：1366/1366 通过、零失败、零跳过，耗时 2007.208 秒，命令退出 0；真实 Windows SSH、真实 Downloads/test 样本、GIF 长会话和隔离 APFS 跨卷均启用。Debug／Release、UI Target 构建及严格签名均通过。日志 `/tmp/bailey-seven-20261124-svg-final-full.log`，结果包 `Test-Bailey-2026.11.24_20-25-29-+0800.xcresult`。测试卷因 `/tmp` 与 `/private/tmp` 挂载路径别名导致自动清理未卸载，随后精确核对镜像及设备并卸载，标记与临时目录均已删除。该证据不覆盖并行任务后续未提交修改。

- 2026-11-24：冻结提交 `05696bb5` 的 Debug、Release、UI Test Target 构建及签名通过；真实样本、授权 Windows SSH、隔离 APFS 卷与完整宿主 `make test` 1366/1366 通过，0 失败、0 跳过，2007.208 秒。日志：`/tmp/bailey-seven-20261124-svg-final-full.log`。仅核销宿主证据，完整 App GUI 与实体设备条件仍保留原阻塞，不据此改为 Go。

- 1c4f2eff 单次完整宿主回归：1365 项，1364 通过、1 失败、0 跳过，make test 退出 2。Quick Open 外部 worktree 索引、监听空窗及三项密集 Git Graph 均通过；F-03 已关闭。唯一失败为实际 Windows SSH 交互式 Rebase。日志 `/tmp/bailey-seven-20261124-full-after-1c4f2eff.log`。524db207 将远端唯一目录、创建结果不确定时的清理与本地快照恢复分开，保留原始错误和阶段；真实 Rebase 三项、SessionStore 十一项均通过。真实四组专项共 53 项、52 通过、1 失败、0 跳过，失败为新增科研 SVG 百次 RSS（另见 SVG 审计）。F-05 已由 05696bb5 冻结版完整宿主回归核销。
- 七格式双窗、系统投递和冷恢复 UI 用例，以及符合动画偏好的 GIF UI 验证已通过实际 `make build:ui` 与 Dev 严格验签；未执行完整 App GUI，不代替独占图形会话。日志 `/tmp/bailey-seven-20261124-preview-ui-build.log`。
- 2026-11-24 19:13 全量宿主（含实际 Windows SSH 和长样本）：1364 项、1362 通过、2 失败、0 跳过，make test 退出 2（Xcode 65）。上次 Markdown 媒体 AX 生命周期项已通过；本次失败为 FileTreeTests 的外部 linked worktree 索引通知及 GitPanelVisibilityTests 的密集图谱 AXPress（3 个失败断言）。原始日志 `/tmp/bailey-seven-features-full-20261124-final-1839.log`，结果包 `Test-Bailey-2026.11.24_18-39-43-+0800.xcresult`。不能作为最终全绿证据。
- 本轮 ffc436c3、1c4f2eff：FileTreeTests 与 ProjectFileIndexTests 的 126 项中 122 通过、4 环境项跳过，随后实际隔离 APFS 跨卷三项和获授权 Windows Tailscale Git／普通目录索引一项全部补过；两组按用例身份 126/126，命令均退出 0。跨卷镜像已卸载清理。GitPanelVisibilityTests 3/3 无跳过、退出 0，密集图谱仍保留原生动作及 48 组合／1026 Changes 的真实结果。原失败在定点未稳定复现，F-03 仍须最终全量确认。日志 `/tmp/bailey-seven-20261124-watcher-green.log`、`/tmp/bailey-seven-20261124-cross-volume-windows.log`、`/tmp/bailey-seven-20261124-graph-green.log`。
- 本轮正式 Debug 与 Release 构建、精简及严格签名全部通过，Release 56 MiB，Dev 严格验签通过；日志 `/tmp/bailey-seven-20261124-resume-debug.log`、`/tmp/bailey-seven-20261124-resume-release.log`。HEAD 1c4f2eff 单次全量启用所有 Downloads/test 样本、长时 GIF、真实 Windows SSH 与隔离 APFS 卷，结果见本节首条。
- R02/R03/R04/R06/R07/R10：实际 FinderDeliveryIntegrationTests、FileTabPersistenceTests、MarkdownResourceScopeTests、SessionStoreTests、Git 和 SSH 文件测试覆盖投递、窗口／项目身份、特殊路径、真实文件类型、草稿与原字节、重命名、断线／恢复和取消。实际获授权 Windows Tailscale 远端验收通过。
- R05/R11：32 MiB 文本与 256 MiB／3200 万像素图片边界；9a7d6835 解决 PNG／普通 TIFF 区域解码，24 MP 区域逐点一致、251 项回归、9286 次边界与 10060 次 ASan/UBSan。bc97976c 真实四小时 WAV（1,382,400,044 字节）与两小时 MP4（7200 秒）实际定位、解码和原文件校验和。容量、性能和特殊 TIFF 的退化边界见图片、媒体 audit。
- R08/R09：原生七格式百次切换、双窗口快照重新创建应用所有者、真实 PNG 三入口版本刷新、SVG 三入口安全像素、独立／嵌入媒体 AX 按钮与独立播放器（d5698ca3、8c6b63b1）；退役后实际资源和暂存文件核对。AVKit 私有控制器留有暂停且无 currentItem 的空壳，不将此写成所有对象零残留。
- R01/R08/R09/R11 的真实 1× 显示器、物理触控板、VoiceOver 播报、减弱动态效果及完整 App 多窗口长会话仍未完成。当前用户使用图形会话，不以抢占桌面或宿主视图替代独立 App；需相应设备与独占 Dev 图形会话。实际设备／完整 App 交叉组合阻塞阶段门禁；分格式证据见其 audit。macOS 27.3／Xcode 27.2、Apple Silicon；按用户确认不要求 15.6 实机，部署目标保留。
- 初次全量 make test 到 1102 通过、1 失败、3 条件跳过后在 SSH 容量用例处超时；1064762f 修正 Git worktree 真实 FSEvents 路径、5 项定点通过，9ce6bad8 修正 .build 标记并用独立 APFS 卷补过全部 3 项。剩余 291 项带真实 SSH 和样本变量完整命令退出 0（零失败／跳过）；不同提交的分段证据不能冒充最终 HEAD 单次全量通过。
- 当前行为文档归 [文件编辑器](../../../docs/features/editor.md)；Git 监听修复同步 [文件管理](../../../docs/features/files.md)。
- 最终受影响回归（e4267d71）：`make test ONLY_TESTING` 选定 FileTabPersistence、FileTree、GitStatusModel、HTMLFilePreview、MarkdownResourceScope、NativeAudioTiming、NativeMediaFile、NativePaneRetentionIntegration 八类共 330 项；启用真实样本和 Windows SSH，实际 329 通过、1 JPEG 长测条件跳过、0 失败，退出 0。启用 JPEG 长测开关定点补测通过，退出 0；按测试身份合计 330/330 通过。初次中断全量、291 项剩余补跑、长媒体定点及本次回归按测试身份去重得到 1359 个最新通过结果；这是跨提交分段证据，不是最终 HEAD 单次全量通过。临时 APFS 测试镜像已卸载清理。日志 `/tmp/bailey-final-affected-20261124.log`、`/tmp/bailey-final-jpeg-boundaries-20261124.log`。
- 最终 e4267d71：正式 `make build` 与 `make build:release` 顺序执行，完整命令退出 0；Debug／Release 再次 `codesign --verify --deep --strict` 通过；Release 精简重新签名后约 56 MiB（du -h）。构建日志 `/tmp/bailey-final-debug-20261124.log`、`/tmp/bailey-final-release-20261124.log`。未替换用户已安装 App。
- 本轮：bbb7b7f7 真实 CENC 音视频保护判定及拒绝／恢复；d768f481 原生 GIF／SVG 无障碍缩放与位置恢复。定点 5 项（含独立 APFS 跨卷三项）全部通过、零跳过、make test 退出 0、Dev 严格签名验证通过。全量重复复测至 580 通过、3 项夹具前缀跳过、0 失败时主动中止以优先核销新增任务；三项已补过，不称单次全量成功。日志 `/tmp/bailey-macos-final-full-20261124.log`、`/tmp/bailey-protected-ax-cross-volume-20261124.log`。

- 2026-11-25 接手：本机共享保存冲突恢复 `bd6e74a2`，定点宿主 5/5、零跳过，`make build` 与 Debug 严格验签通过；详见 [CSV P2 F-02](../csv-table-view/audit-p2.md)。未执行新完整 App 用例，未替换已安装 App。当前仅内置 Retina XDR 与内置扬声器，未确认独占图形会话；1×／外接 HDR、多屏、实际音频输出切换、睡眠、中文 IME、VoiceOver 播报、物理触控板、减弱动态效果及双窗长会话均不能由宿主核销。此前七格式双窗冷启动证据保留。
- 扩大宿主回归（冻结 `bd6e74a2`，含真实样本及 Windows SSH）：选中 297 项，主动中止时 233 通过、1 失败（HTML/SVG 净化诊断的过时精确集合）、2 条件跳过（JPEG 长测未启用、未配置独立测试卷），61 项未完成；不视为全量通过。真实 Windows 旁车、Git raw save 与 CP936 三项均通过；HTML 综合真实资源样本通过。日志 `/tmp/bailey-late-publication-affected.wyntrfWs`，命令因中止退出 143。

- `2f8482e0` 单独补测上述过时断言与 SVG pattern，2/2 通过、零跳过，命令退出 0；扩大回归仍为中止，不合并冒充最终单次全量通过。
