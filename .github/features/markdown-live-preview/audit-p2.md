# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go（已知正确性阻塞完成修复与跨环境验收；F-01 依用户决定延期）。
- **依据**：1× CI 15/15、当前 Mac 宿主 230 通过／1 授权 SSH 跳过、真实 GUI 5/5；Debug／Release 构建和签名通过。未测边界在下文逐项披露，不视为已通过。
- **本轮范围**：macOS 15.6 实机门槛已获用户免除，最低部署版本不变；108.3 ms 尾部卡顿按用户决定接受，不作为本轮阻塞。

## 任务与改动

- **P2-T1**：`MarkdownFilePreview` 根据 `FileTab.markdownRequestID` 合并解析、取消旧结果；
  `Project.setMarkdownMode` 用 Dock 原有标签挂载预览，不复制原文缓冲。
- **P2-T2**：`Project.openMarkdownLink` 检查来源和实际授权目标；视图切换走 `FileTab` 原有保存、Undo 和关闭保护。
- **P2-T3**：`MarkdownResource` 经拥有源文件的后端读取；静态 HTML/SVG、图片及按需 AVKit 路径各有容量和作用域约束。
- **P2-T4**：`MarkdownMath`、`MarkdownFootnotes` 保留解析改写的原文范围；公式和 Mermaid 原生绘制，失败提供可读原文。
- **P2-T5**：`MarkdownDocument` 与 SwiftSoup 保留 HTML 实体原文区间；ClipView 事件转为统一视口坐标。
  Windows Tailscale 实机 CRLF 并排滚动、双击准确插入及撤销、原文件校验和通过。
- **P2-T6**：`MarkdownReaderCoordinates` 和 `MarkdownSelectionText` 共用选区，已去掉预览的 SwiftUI 局部选区路径。
  滚动后的两种实际选区及剪贴板、Unicode、HTML、主题切换均有针对性回归。
- **P2-T7**：标题大纲和折叠归 `FileTab`；富内容查看和脚注返回复用原生视图，真实 VoiceOver 折叠/展开通过。
- **P2-T8**：五类提示的色彩和窄宽布局有像素证据；GFM 引用任务由失败复现到修复，软硬换行、只读点击和原文不变通过。
- **P2-T9**：两万行混排隔离 App 能真实到尾、回首、编辑且不写盘；真实 SSH 断开仅用例专属 master，
  保住草稿并在恢复时重新读图和保存远端，未回退到本机。

## 发现项

## 发现 F-03

- 任务：`P2-T9`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownDocument.swift`
- 摘要：`每个同名标题从同一后缀重新探测；6000 重复标题比相同数量异名标题慢 18 倍`
- 风险：`大纲、锚点跳转和编辑后发布预览等待重复分配`
- 预期修复：`每种已重复的标题从下一个未探测后缀继续，保留跨标题全局冲突检查`
- 验证：`对照相同规模异名标题、数字后缀冲突的语义回归、折叠与锚点场景`
- 解决证据：`f09694c0；6000 个重复标题 Red 2.154s / 18.4 倍，Green 0.110s，编号和数字冲突输出相同；74 条定向通过。`


## 发现 F-02

- 任务：`P2-T9`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/NativeCodeTextView.swift`
- 摘要：`未折行源码的 AXLineForIndex 和 AXRangeForLine 都会排版目标前的大量不可见段落`
- 风险：`辅助功能或 XCUITest 读位置时，一次查询会阻塞长文 App 的主线程`
- 预期修复：`用原生 UTF-16 行索引双向回答未折行、无自定义内容投影时的查询，保留 AppKit 折行与折叠映射`
- 验证：`两万行宿主反复查询计数、与原生 AX 输出对照、Release Dev 实际跨进程查询；整窗性能另见 F-01`
- 解决证据：`959d31ab、89646ee0；任一查询不再排版两万行前缀，22 项定向宿主回归通过；签名 Release Dev 跨进程真实查询各 30/30 正确，最差分别为 0.119 ms 和 0.043 ms。整窗卡顿另见 F-01。`


## 发现 F-01

- 任务：`P2-T9`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`Bailey/Editor/MarkdownPreview.swift`
- 摘要：`两万行混排 Release 功能用例通过，但实际 App Instruments 捕获 45 条卡顿，最大 758.3 ms`
- 风险：`宿主热视口 P95 约 13 ms 不能证明实际 App 首屏、跳转和编辑流畅`
- 预期修复：`使用同夹具定位长耗时线程及操作阶段，先排除启动、XCTest 访问和真实首次布局的混合影响，再修复实证热点`
- 验证：`隔离 Release Dev 的所选两万行 GUI、Animation Hitches 和按现行计划的定向性能复验`
- 解决证据：已修复导致屏外跳转阻塞的两层布局工作；整窗仍有 108.3 ms 尾部事件，
  用户 2026-11-23 明确接受该尾部事件；热操作和长时内存未完整量化，延期项不等于已解决。
- 继续定位：消除原生 AX 前缀后仍有 228 条主线程样本在 `ScrollViewProxy.scrollTo` 内，
  其中 204 条进入视图 body。这个代理查找子视图身份时展开屏外 Markdown 行；
  行身份应由懒布局的一对一目标提供，而不是每个分支各挂一个内层 `.id`。
- `751ebf49` 删除旧代理路径，同一行只由懒布局注册一次。新命令先到块，原有桥接再用实际字形、
  公式或图片矩形细调；阅读锚点、折叠、原文选区和保存继续各归原所有者。


## 验证与未覆盖

- **2026-11-23 最终正确性验收**：CI 验收时 PR #101 HEAD 为 `fb2658c4`；历史合并后，
  `0743dd15` 负责稳定文档坐标、`dce36f98` 负责原生 `NSClipView` 边界变化恢复阅读锚点。
  合并前后的源码及测试 tree 完全一致；CI 仍记录当时真实运行的旧提交。
  首次文字、Canvas 公式和图片在 CI 1× 滚动环境准确回到源码位置。
  [CI #45163210156](https://github.com/chiimagnus/Bailey/actions/runs/45163210156) 15/15，
  删除诊断输出后的 [CI #45164989969](https://github.com/chiimagnus/Bailey/actions/runs/45164989969) 再次 15/15。
  本机相关宿主 140 项／139 通过／1 项需授权 SSH 环境跳过，持久化／生命周期 91/91，
  真实 GUI 定向 5/5；`make build`、`make build:release` 和对应严格验签均退出 0。
  已整包更新 `/Applications/Bailey.app`，未退出、启动或重启正式 App。
- **延期且未冒称完成的条件**：32 MiB *富 Markdown* 的实际 App 解析及内存极值
  （已验证原生文本文件边界，但不是该组合）、反复开关后的长时 retained heap／RSS
  （以原生内容生命周期 26 项宿主作部分替代）、缩放／减弱动态效果／触控板专项
  （当前 GUI 环境未分别执行）、SSH 断线＋旧资源返回＋项目切换三因素同场景
  （单项授权 SSH／过期结果证据存在，但组合未执行）。
  这些不是已证实的功能缺陷，也不是已通过的验收；
  后续若列为发布强制要求，必须在对应环境补测，发现异常重新打开 P2-T9。

- 2026-11-23 全量 CI [#45102596345](https://github.com/chiimagnus/Bailey/actions/runs/45102596345)
  在旧提交 `751ebf49` 上运行：宿主 1,246 项、5 失败、22 跳过；GUI 331 项、
  36 个用例失败、9 跳过。定向 CI [#45113933622](https://github.com/chiimagnus/Bailey/actions/runs/45113933622)
  复现了 Markdown 段内字形／公式／图片位置恢复与 Git 主题采样失败，SSH 进度超时用例单独通过。
  两项运行均在旧提交，不代表当前 PR。
- 历史记录：PR [#101](https://github.com/chiimagnus/Bailey/pull/101) 当时位于 `f12a358e`。
  菜单／Git／Files 定向 GUI CI [#45139516620](https://github.com/chiimagnus/Bailey/actions/runs/45139516620)
  与 [#45141511479](https://github.com/chiimagnus/Bailey/actions/runs/45141511479) 通过；
  `66d59583` 的定向宿主 CI [#45141516315](https://github.com/chiimagnus/Bailey/actions/runs/45141516315)
  公式通过，文字和图片的首次阅读位置恢复失败。`f12a358e` 不再在第一次布局成功后清除阅读锚点；
  当时定向 CI 为 [#45148222528](https://github.com/chiimagnus/Bailey/actions/runs/45148222528)，后续结果以上方最新记录为准。
- 历史记录：当时本机完整 `SwiftMarkdownLayoutTests` 15/15，20,000 行混排编辑 GUI 1/1 通过；
  旧提交 `dd5cad7d` 的全量 CI [#45136578416](https://github.com/chiimagnus/Bailey/actions/runs/45136578416)
  宿主失败、当时 GUI 尚未结束。F-01 的整窗尾部卡顿、热操作和内存判据当时尚未核销。

- 续查 F-02 时用原 CPU 样本核对调用链：2,509 条 TextKit 片段枚举样本中，
  2,366 条来自 AppKit 响应 `AXLineForIndex` 时从文首计数，而非 Markdown 解析。
  修复前，宿主两万行首次末段查询约 711 ms，30 次共请求 19,842 个原生段落；
  `959d31ab` 后查询不请求段落，30 次最慢约 0.005 ms，21 项定向宿主回归通过。
  逐 UTF-16 偏移和 AppKit 对照了包括分页符、折行、CRLF、空文件、emoji、插入及撤销的情况；
  原生折叠 Diff 继续走其自定义布局。同一提交的签名 Release Dev 打开两万行混排，
  30 次真实跨进程 `AXLineForIndex` 均返回正确行号，P50 0.028 ms、P95 0.077 ms、最慢 0.118 ms。
  这些数据仅覆盖行号查询，不是整体 App 帧率。
- 取消授权弹窗后的实际并排 CPU 采样有 5,968 条 App 主线程样本。1,818 条 TextKit 片段枚举中，
  1,707 条来自另一个方向的 `AXRangeForLine`，没有经由旧的 `AXLineForIndex` 布局路径。
  另有 1,101 条经过插入，其中 1,035 条在 TextKit 文本存储更新，主要是搬移已有文本元素的范围。
  `89646ee0` 让两种 AX 查询共用同一索引；反向查询 Red 约 740 ms、19,842 个段落，
  Green 约 0.005 ms、零个段落。含换行的返回值逐行与 AppKit 对照，22 项定向宿主回归通过。
  `make build:dev CONFIGURATION=Release` 构建及验签通过；该版本的真实跨进程查询各 30 次全部正确，
  行号 P50 0.026 ms、P95 0.052 ms、最慢 0.119 ms；文本范围 P50 0.027 ms、P95 0.042 ms、最慢 0.043 ms。
  同一夹具的 15 秒并排 Time Profiler 复跑中，2,972 条主线程样本仅 75 条枚举 TextKit 片段，
  没有通过两条已修复的原生 AX 前缀布局路径；插入采样从 1,101 条降至 41 条。
  本轮为人工驱动，报告采样分布，不换算成端到端延迟。
- macOS 27.3（26C5035r）、Xcode 27.2、Apple Silicon；按用户要求改用 `make test` / `make test:ui` 的 `ONLY_TESTING`，
  不重跑中断且无完整结果的全量测试。GFM 与语义复制宿主 74 项通过；另 6 项容量、媒体和混排宿主回归通过。
  SSH 断线宿主用例和 CRLF 双向定位 GUI 按 `windows-tailscale` 实际执行，通过后只清理各自夹具。
- 上一轮 `make build`、`make build:release` 均退出 0，正式 Debug 和 Release 通过 `codesign --verify --deep --strict`，
  可执行文件最低部署版本均为 15.6。上一轮构建和测试日志见 `/tmp/bailey-p2-delivery.tGfrBo`。
- GUI 证据包括真实主题联动、折叠、跨结构选区、相同 AST 块内双向滚动、滚动后精确命中及两万行混排。
  VoiceOver 字幕读出正文与 `Completed, image`；用系统 VoiceOver 的默认动作确实折叠/展开，展开前后原字节一致，
  已恢复 VoiceOver 与输入法原设置。表头有原生辅助功能语义，但没有逐个听读全表。
- Debug 宿主窄列深色 500／5,000／20,000 行各 30 次热滚动，P95 为 12.7／13.2／13.0 ms；
  20,000 行解析约 725 ms，首次宿主绘制约 42 ms，冷跳末约 1.12 s。
  前者不是实际 App 帧间隔；峰值 RSS 属于共享宿主进程，不是单篇文档 retained heap。
- 上一轮 `make test:ui CONFIGURATION=Release ONLY_TESTING=BaileyUITests/MarkdownPreviewUITests/testRapidEditsInLongSideBySidePreviewNeverRestoreOlderSnapshot`
  退出 0，真实 20,000 行 App 用例通过（约 31 s，包括测试启动和自动化操作）。
  同一次 Release Dev 的 20 s Instruments 记录中有 45 条归属于 App 的卡顿事件；其中位 66.7 ms、
  P95 133.3 ms、最大 758.3 ms。这是卡顿事件分布，不是全部帧的分布，不支持宣称优化版性能达标。
- 清除系统键盘遗留的覆盖浮窗后，优化版同一用例再次通过（约 38 s）。同时从进入并排的动作起录制 16 s CPU 样本：
  9,273 条主线程样本中，2,509 条包含 `NSTextLayoutManager` 枚举，2,168 条经过 `NativeCodeTextView.insertText`，
  338 条经过 `MarkdownPreview.scroll`；同一条样本可以重叠计入。热点先落在原生编辑和布局链路，
  样本不是 758 ms 事件的独立分解，不能据此把卡顿归咎于解析器。
  两次失败的 CPU 复跑均在打开文件前被浮窗挡住所选文件行，不计入 Markdown 性能结果。
- 本轮同一 Release GUI selector 在预检返回零个用例（退出 2），宿主拼音探针也未进入用例。
  桌面实际显示 XCTest 的 UI Automation 授权提示，要求 Touch ID 或密码；已取消，未代为授权。
  取消后在签名 Release Dev 上手动复验：窄窗并排源码和预览都到达第 20,000 行，回到文首快速改两次标题，
  预览显示最新标题；撤销与重做各自更新预览。实际磁盘在专注编辑期间保持原样，显式保存仅改变首行。
  32 秒 Animation Hitches 采样期间，授权弹窗挡住了并排入口；虽捕获源码操作最慢 1208.3 ms，
  不能与上一轮完整并排的 758.3 ms 对比，也不能据此判定 F-01 通过。
  在最新签名 Release Dev 的真实并排执行文尾往返、输入和撤销时，15 秒 Animation Hitches 样本有 42 个事件，
  其中 14 个超过 16.7 ms；事件 P95 325.0 ms，最慢 366.7 ms。文件实际字节未改。
  手动与早先 XCTest 采样的时长、节奏不同，不作前后帧率对比。F-01 仍阻止完成。
  本轮测试、截图及采样见 `/tmp/bailey-ax-line-delivery.3ar1J3`。
- 最新一轮在当前系统重新运行同一条 Release 两万行并排 GUI，两次均通过。从打开并排时开始采样，
  最大卡顿 741.7→108.3 ms，事件 P95 125.0→25.0 ms，超过 16.7 ms 的事件 33→6。
  两次分别有 66／79 条记录；总数包含短事件，不是帧率，也不代表没有剩余卡顿。
  49 项定向宿主用例通过，覆盖 500／5,000／20,000 行窄窗位置、真实公式和图片视口、宽表格及原生合成。
  初次组合 GUI 有 5 个测试未通过；失败截图和 AX 层级仍含可见标题，进一步证实 XCTest 查询映射为 `Other`。
  按已有标题 ID 定位并继续断言可见标签和视口后，脚注折叠／返回和前文编辑后的阅读恢复各通过一次。
  单独复验的交替双向滚动、折叠章节链接、同步开关、两万行快速编辑全部通过；
  加上初次组合中的成功用例，本轮共 12 个不同的定向 Release 界面用例通过。
  另在隔离 Release 直接按实际控件验证折叠、脚注返回和屏外链接目的地可见，源文件未被修改。
  新的同场景 Time Profiler 记录 1,569 条主线程样本，未见旧代理路径；约 309 条涉及辅助功能，
  185 条有 TextKit 调用，且允许重叠。该样本不证明剩余最长事件是单一子系统所致。
  无 XCTest 的 15 秒键盘补测仍有 7 条超过 16.7 ms，最慢 308.3 ms。
  当时系统拼音仍启用，合成输入和撤销没有恢复为原夹具的首行；与历史键盘基线不做定量前后比较。
  合法的真实拼音编辑、撤销和保存由上面的定向用例及下面的用户实测分别核对。
  独立 Release 包严格验签、正式 Debug 构建及验签通过，未替换运行中的正式版。
  本轮证据见 `/tmp/bailey-t9-root.X4u45s`。
- 早先合成按键无法显示候选。本轮由用户在隔离 Release 的并排编辑器实际操作并确认看到了系统拼音候选，
  原生编辑器及 Markdown 预览都显示提交的中文。原生撤销改变内容、重做按字节恢复，
  两次显式保存都与当时编辑器的实际字节一致；未操作真实用户文件。
- 没有可用 macOS 15.6 运行环境；此轮经用户同意不作为门槛，已核对最低部署版本仍为 15.6。
  远端断开与恢复、过期结果取消、切项目各有证据，但没有在一次真实 GUI 流程中重叠触发这三个条件。
- 32 MiB 边界核对了真实 TextKit 文件打开、编辑、落盘与重开，不等于相同体积的富 Markdown 已通过性能验收。
  实际 App 的长时 heap/RSS 回收、系统缩放/减弱动态效果和触控板专项没有全部核销。
- 用户文档见 [Markdown 阅读预览](../../../docs/features/markdown-preview.md) 和 [测试入口](../../../docs/testing.md)。
  没有安装、替换或重启使用中的正式 Bailey。

