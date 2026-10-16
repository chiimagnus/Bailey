# P1 执行证据（2026-10-16）

## 环境与范围

- 起点 `4247eea`，正确性修复 `b6d7368`。MacBook Pro / M1 Pro / 32 GB，macOS 27.2 (26B5101f)，Xcode beta 27.0 (27A5209h)，Swift 6 Debug，锁定依赖未变。
- 代表热路径：同进程反复打开 400 KiB Swift（409600 UTF-8 字节、360448 UTF-16 单元），900×600 原生窗口、13pt 等宽字体、深色、不换行。两批各 30 次，真实 FileTab → SourceTextEditor → STTextView → 插件 → 渲染属性。临时实验类进入现有 XCTest 目标，运行后移回本地 `build/performance/editor-git-20261016/PerformanceBaselineTests.swift`，不新增 runner 或产品诊断平台。
- 五个独立隔离 App 冷进程读取相同 512 KiB Swift。Swift、TSX、Markdown 的独立隔离 App 截图已实际查看；包含中文、emoji、独立 TSX 与围栏着色。不是菜单点击 E2E，未验收输入后高亮，已知编辑错误留 P3 正确性任务。
- 合成样本在本地 a/b 两个全新目录独立生成，manifest 相同；包括 1000 个 Git 变更、rename、unborn、分页历史与真实 merge 冲突。脚本拒绝覆盖目录，未使用用户仓库写操作、global config 或 SSH。

## 实际结果

热实验未附采样器；单位 ms，顺序为 median / nearest-rank p95 / max：

| 边界 | 批 1（n=30） | 批 2（n=30） |
| --- | --- | --- |
| FileTab init | 0.477 / 0.545 / 0.767 | 0.459 / 0.500 / 0.571 |
| 本次文本加载结束 | 0.479 / 0.547 / 0.785 | 0.461 / 0.503 / 0.574 |
| 原生安装／同步 layout+display 返回 | 36.646 / 39.965 / 90.650 | 37.348 / 39.317 / 39.767 |
| 首次非空前景渲染属性 | 268.092 / 284.031 / 451.710 | 268.955 / 297.900 / 299.150 |

安装返回不是屏幕完成呈现，首个颜色不是高亮全部稳定。两批中位数接近；首次编译／冷原生资源影响批 1 最大值，不删除该样本。仅据这组数据不能声称文件 IO 是主导，也不能用首次颜色对外宣称高亮已全部完成。

五个独立进程从发起启动到 AX 可读出实际文件文本的上界（含 Python／Peekaboo 启动与轮询开销）：2.030、1.587、1.636、1.567、1.533 秒；median 1.587，max 2.030。并非磁盘冷缓存或精确绘制计时，不报冷 p95，不与原生组件的毫秒数混算。

## 归因及准入

- Xcode beta 的 Time Profiler attach 未找到指定隔离进程；launch 明确失败。系统日志证实 AMFI 以 `com.apple.private.amfi.version-restriction entitlement version` 拒绝 DTServiceHub。用户已明确继续用 beta；没有切换全局工具链、安装 stable 或绕过签名。
- 改用 `/usr/bin/sample`，只附本轮隔离 PID。五个启动样本及原生循环额外 4 秒样本均已保存，采样运行与无采样延迟数据分开。原生样本定位到 `SyntaxHighlightTextInterface.applyStyle → STTextView.addAttributes → NSTextStorage` 的无效字体事务，以及首次 InputEdit transformer 的全文扫描；不是把源码猜测当作 trace。
- P2 的同步 init 和错误读取容量边界是已证明的入口／数据问题，虽热 IO 中位数很小仍应修。P2-T2 字体事务已命中，可以移除。不据此预建通用加载器／parser service。
- P3 首先修编辑和字节精确性，再测尾部坐标与同步根 parse；当前首次 parse 已异步，不能凭这次打开实验把 threshold=0 当成已选措施。query 失败闭环必修；共享、跨 edit 子树与额外索引继续各自准入，不提前通过。
- Git／Files／Diff、输入后高亮收敛、峰值/释放的可比测量尚未取得；必须在相应 phase 改动前补该路径基线，不把它们记作已提速。P4、P5 的候选排序未作结论；SSH 没有本轮获准专用主机。

## 正确性验证

- SyntaxHighlightingTests 原实现实际 Red（字节列、换行和非法位置），修复后 Green；调用生产 coordinator 和真实 Parser，检查所有 UTF-16 位置及最终树。
- `make test`：241 项，0 failures，3 项真实 SSH 用例按条件 skipped；没有提供专用主机参数。
- 最终 `make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests` 通过；`make build` 与严格验签通过。
- 原生循环实验两次均执行通过，第二次只作采样归因、不混入上表。未执行输入/撤销完整 E2E、真实 SSH、正式用户会话重启或恢复。
- 原始日志、样本、manifest、截图、冷数据、AMFI 证据及本地实验源统一在 `build/performance/editor-git-20261016/`。这些本地资料不提交。
