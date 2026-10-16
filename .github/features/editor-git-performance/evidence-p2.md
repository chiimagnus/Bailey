# P2 实施与验证证据

## P2-T1 真实链路

- FileTab.init 只建立身份和 loading；loadIfNeeded 同时服务 FileViewerView 和 waitForText，ignoreGitPaths 无需原生挂载也能读取后追加。真正的 clean 外部刷新仍可替换读取，等待者跟随同目标的新任务。
- 普通文本 backend.read 传 5 MiB；读和 UTF-8 解码在一个明确 @concurrent 入口，NSImage 在 MainActor 建立。图片仍不新增容量限制，无效图片回文本／大小判断。删除 readImmediately、本机同步 init 和远端 init 自动启动。
- rename 仅继续确实在途的首次读取；尚无消费者的标签 rename 不启动 IO。读取保留代次、dirty、取消和断线检查；句柄只由本代次清理，不新增影子版本。path 的唯一变更入口 updatePath 必定失效读取并推进 targetGeneration，backend／只读资格的唯一变更入口也推进目标代次，因此删除读取末端重复 path 比较及保存末端重复 path／readOnly 比较，保留真正的目标代次核对和发起资格检查。
- 固定 host 的实际命令连接结果通过一个语义通知接入现有 Project.rebindRemoteTabs，弱订阅随项目释放。未知初连可操作；已知断线保留原缓冲并只读。重选只对已知断线原 host 作一次有现有 timeout 的 stat 探测，面板查询也可恢复；没有后台重连循环或初始恢复逐标签探测。
- 断线发生在未加载标签时显示原机器的不可用原因，不留下空 loading。原生 isEditable 及 Vendor 的 AX 值／选中文本写入共同守住只读；DiffTextView 两个重复 override 同 task 删除。
- Diff 加载失效的公共拥有者修复提前自 P5-T3：invalidateReload 同时推进代次并结束 loading，编辑、保存、断线、换通道均走同一入口。保留完成回写的原代次检查，不能让旧读清新 loading。

## 实际验证

- 新增受控固定 host 断线回归实际 Red；修复后 FileTabTests 20 tests / 0 failures。原生 AX 值及选中文本替换只读不改文本，仍可读取选择和内容。
- DiffTabTests 在既有“读中输入／撤销再读／断线”路径追加 loading 断言，修复前实际两项 Red，统一失效后 16 tests / 0 failures。
- FileTabTests 覆盖不消费不读、重复 wait 一次读取、未消费 rename 不读、在途 rename 旧结果不胜、同目标替换读取等待、容量 0/cap−1/cap/cap+1、缺失／二进制、保存中输入、失败、原生保存、ABA、关闭保护。固定 host 状态事件检查断线、保留 dirty、拒绝保存及重新连通恢复资格；没有向该随机 fixture host 发 SSH。
- 所有受影响的 FileTab 直接构造测试迁移为显式需求／等待，而非保留同步兼容接口；FileTab 与窗口 fake 超限抛 tooLarge，不截断冒充成功。
- 当前 Debug 隔离 App 经恢复入口打开原 512 KiB Swift，AX 读到实际原文，已查看 `p2-loaded.png` 的原生着色；未把加载完成或截图当性能提升／输入 E2E。
- 全量回归发现 SessionStoreTests 通过 Project.openFile 间接构造标签后直接编辑未加载缓冲；同任务迁移为显式 waitForText，不保留产品同步兼容路径。定向 SessionStoreTests 和随后完整 make test 247 tests / 0 failures / 3 SSH skipped；Debug／Release 构建及严格验签均通过。
- 补充真实 NSWindow/FileViewerView 的连接中断、原生 keyDown／AX 拒绝、重连后同一文本表面可编辑及 undo 检查，实际通过，未调用真实 SSH。
- 增补“缺失文件读取失败后重新创建、同标签再请求文本”的回归，实际 Red；根因是按需入口只接受 loading，旧 unavailable 被永久当成终态。共享按需入口现接受新的显式失败重试，不在 ignore caller 添加绕过或自动重试循环。
- 最后新增原生断线／重连及失败恢复后，FileTabTests 21 tests / 0 failures；最终 Debug 构建和严格验签通过。此前 Release 已通过；后续 P2 阶段 Gate 再核对组合结果，未把未运行的新用例算进前次 247 项结果。
- Peekaboo 后台 Tab 点击无 AX press，菜单路径操作 partial；核对原文未切换，不记为成功，随后仅按本轮 PID+启动身份退出该隔离实例。用户原 PID 15884 未操作。
- 日志在 `build/performance/editor-git-20261016/p2-*.log`；完整自动回归／构建及最终提交以实际后续结果回填。未执行真实 SSH、用户 App 重启或恢复。

## P2-T2 颜色样式与单变量对照

- 先新增真实 SourceTextEditor/STTextView 插件的绿色等价基线：实际 comment 渲染色、中文/emoji 原文、clean、undo 无污染和 19→25pt 全文换字体均通过；移除字体事务后同样通过（SyntaxHighlightingTests 2 tests / 0 failures）。没有为纯性能替换制造错误的 Red。
- 删除 coordinator 无条件同值 font setter、每 token 字体字典、clearStyle 的 font 写入及通用“其他样式写正文”分支；现在 provider 只返回颜色。metadata 过滤、别名／层级颜色回退、空范围与边界转换、原生弱引用仍在，SourceTextEditor 的真正字体变化仍应用。
- 新实现额外 sample 4 秒中，着色进入 rendering attributes；原先 `SyntaxHighlightTextInterface.applyStyle → STTextView.addAttributes → NSTextStorage` 支路在源码已删除，采样也未再见该支路。
- 为隔离按需 IO 和字体措施，另作仅字体 A/B：两边均保留 P2-T1 加载器，同一个本地 XCTest 实验、409600 字节 Swift、900×600/13pt/深色/不换行；每边两批各 30。旧字体代码仅在本地实验短暂恢复，完成后立即还原采用实现；没有提交旧路径或保留切换配置。采样另跑，不混入计时。

单位 ms，median / nearest-rank p95 / max：

| 边界 | 旧字体批 1 | 新颜色批 1 | 旧字体批 2 | 新颜色批 2 |
| --- | --- | --- | --- | --- |
| init | 0.015 / 0.018 / 0.042 | 0.013 / 0.032 / 0.033 | 0.015 / 0.018 / 0.018 | 0.013 / 0.019 / 0.027 |
| 文本加载结束 | 12.593 / 14.034 / 15.019 | 11.506 / 14.186 / 18.571 | 12.724 / 16.233 / 20.011 | 11.572 / 12.784 / 12.881 |
| nativeInstall 返回 | 52.319 / 56.554 / 103.469 | 47.054 / 50.639 / 88.916 | 52.459 / 58.013 / 61.055 | 47.336 / 50.119 / 50.250 |
| 首个前景渲染属性 | 301.523 / 323.145 / 474.348 | 245.039 / 250.985 / 408.911 | 305.107 / 317.518 / 324.353 | 245.639 / 250.032 / 259.358 |

- 此合成原生路径减少约 5ms 安装阶段、约 56–59ms 首颜色等待；不是完整 App 绘制／高亮稳定或所有语言的提速承诺。加载结束发生在安装前，其约 1ms 波动不能归因于字体。
- 相较 P1 同步 init，构造本身降为约 0.013ms，但异步加载／调度使单次 nativeInstall 边界约 37→47ms；不能宣称每个阶段都变快。组合首颜色约 269→246ms。P6 仍需检查真实首屏／可输入终点，不能用本表掩盖边界变化。
- 原始对照：`p2-load-old-font-perf.log`、`p2-font-perf.log`；额外 `p2-font-profile.log`／`p2-font.sample` 仅归因。本地实验类运行后移回 build/performance，不新增永久测试 runner。
- 移走临时实验类并恢复采用实现后，阶段组合 `make test`：249 tests / 0 failures / 3 SSH skipped；`make build` 与严格验签通过。此前本地 STTextView AX 补丁已通过 Release 构建／严格验签；没有重启或退出用户现有 Kero，也尚未执行正式安装。
