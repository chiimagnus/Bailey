# P1 十万行 Git Diff Debug／Release 热态基线

2026-11-06，Apple M1 Pro（32 GiB）、macOS 27.3（26C5035r）、Xcode 27.2。
在相同的独立临时 Git 仓库中建立 100,000 行 Swift 文件，约 2.28 MB，
HEAD → Index 与 Index → Worktree 分别改变第 50,000 与 50,001 行。
使用真实 `DiffTab`、`DiffNativeSurface` 和附着于离屏 `NSWindow` 的 TextKit 2，
逐次等待真实可展示数据、原生布局和 `cacheDisplay` 绘制，
检查两来源的正文及磁盘、Git Index 的原始字节。
每来源先单独采集首次标签，再采集 30 次热态；每次释放测试拥有的视图并解除
实验中保留的 TextKit layout manager。两组交错执行，避免单边顺序优势。

| 配置／来源 | 阶段 | 热态中位 | P95 | 最差 |
| --- | --- | ---: | ---: | ---: |
| Debug Staged | Git 模型 | 432.17 ms | 476.98 ms | 504.46 ms |
| Debug Staged | 原生布局 | 436.45 ms | 481.24 ms | 508.92 ms |
| Debug Staged | 组件像素 | 440.07 ms | 484.81 ms | 512.75 ms |
| Debug Unstaged | Git 模型 | 531.34 ms | 607.32 ms | 618.28 ms |
| Debug Unstaged | 原生布局 | 2199.69 ms | 2269.81 ms | 2335.08 ms |
| Debug Unstaged | 组件像素 | 5392.96 ms | 5504.33 ms | 5572.30 ms |
| Release Staged | Git 模型 | 163.47 ms | 220.80 ms | 263.29 ms |
| Release Staged | 原生布局 | 167.64 ms | 224.84 ms | 267.49 ms |
| Release Staged | 组件像素 | 171.21 ms | 228.27 ms | 271.04 ms |
| Release Unstaged | Git 模型 | 280.70 ms | 392.67 ms | 398.85 ms |
| Release Unstaged | 原生布局 | 1044.53 ms | 1156.69 ms | 1171.08 ms |
| Release Unstaged | 组件像素 | 2502.16 ms | 2634.90 ms | 2636.65 ms |

首次标签累计毫秒：Debug Staged 506.71／534.65／564.75，
Unstaged 615.20／2324.46／5528.59；Release Staged 144.78／168.41／198.17，
Unstaged 270.43／1090.67／2586.26，顺序为模型／原生／组件。
峰值进程 malloc in-use 观测分别约 1010.8／1024.3 MiB；它是整个隔离
XCTest 宿主的瞬时在用字节，不是某个标签的独占内存或稳定 retained heap。
内存余量经 `memory_pressure` 核对，实验没有修改 Git Index 或工作区。

- Debug：`make test ONLY_TESTING=BaileyTests/NativeDiffTabTests/testAuditHundredThousandLineHotDiffReadiness`，
  1 项，0 失败，218.735 秒，Make 退出 0；
  `build/git-diff-p1-100k-hot-debug.log`。
- Release：`make test CONFIGURATION=Release VERSION_FLAGS=ENABLE_TESTABILITY=YES ONLY_TESTING=BaileyTests/NativeDiffTabTests/testAuditHundredThousandLineHotDiffReadiness`，
  1 项，0 失败，120.454 秒，Make 退出 0；
  `build/git-diff-p1-100k-hot-release.log`。
- 一次性 XCTest 补丁在 `build/git-diff-p1-100k-hot-experiment.patch`；
  测量后已从常规测试源码移除，避免为日常全量回归增加数分钟。

**解释：** Release 显著缩短模型、TextKit 和组件绘制等待，但 100k Unstaged
即使优化构建仍需约 2.50 秒组件绘制，而 Staged 仅约 0.17 秒。
`DiffCodePaneView.layout` 的首次 `ensureLayout(documentRange)`、编辑态折叠
以及 `DiffRowGeometry`／ghost 绘制是必须继续追踪的所有者；
以上是分段时间，不是逐函数 CPU 排他归因，不能据此直接认定某个调用
单独占了全部延迟，也不能以换 Release 取代正确性与性能修复。

**未覆盖：** WindowServer 首像素、实际可输入和语法色稳定、真实独立冷进程、
CR／Unicode 可变行高、折行／Ghost 极端组合、无失效布局的低成本 17 次深跳、
以及完整 App 多标签关闭后的 heap。P1-T1／T5 仍需核销，P2-T1／T4 和 P4-T4
负责实现后与此同机基线比较。此实验不宣称通过几何准入。
