# 源代码编辑器：稳定滚动范围与按需布局

## 背景与问题

用户重新明确：**问题不在触摸板手势本身，而在上下滚动时内容按需布局、滚动条滑块长度或位置异常变化，阅读过程出现跳动和卡顿**。实际发生问题的 `kero/Files/FileTreeModel.swift` 仅 **382 行、16,050 字节**；不能把原因归于大文件，也不能用滚动条拖拽较顺畅来推断触摸板事件有 bug。

Kero 会将文本**完整读入** `FileTab` 和 STTextView，并非滚动到哪里才从磁盘加载哪里；按需发生的是 **TextKit 2 的文本排版和可视片段绘制**。现有 STTextView 的 `updateContentSizeIfNeeded()` 在视口布局完成时根据文末布局**估算文档高度并更新 documentView 的 frame**，`usageBounds` 变化还会触发约束更新；这些与滚动条跳变有直接机制关联，尚需实际记录文档高度／滑块／视口位置来确认是否为最终根因。此前 P3 输入、解析及跳转性能数据不能证明滚动几何稳定。

此问题独立于 [editor-git-performance](../editor-git-performance/idea.md) 的 Git／Diff 任务；共享 STTextView 修改须保护 Diff 的固定行高与同步滚动。另有两个与资源占用直接相关的当前实现：`SourceTextEditor.textViewDidChangeText` 每次编辑取 `textView.text` 全文，`FileTab.refreshDirtyState` 随即逐字节比较保存基线；`SyntaxHighlightCoordinator.didChangeContent` 也每次取得全文供 Tree-sitter 读取，`TextCoordinateIndex.replace` 会平移编辑位置之后的全部行起点。这些是已确认的工作量路径，实际耗时与分配仍需实测。`FileTab.maxTextBytes = 5 MiB` 还可能拒绝真实十万行文件；不能只用每行几个字符的样本掩盖限制。

## 需求与边界

1. **稳定滚动几何**：无软换行且经验证为固定行高的代码文件，在内容／字体／窗口不变时，滚动到新区域不应再次修改总高度或滑块比例。软换行／可变行高要以文本锚点维持屏幕阅读位置，确保滚动映射单调、文末可达，不能随着懒布局产生肉眼可见的大幅跳位；真实编辑、字号／宽度变化允许必要的几何修正。
2. **同时覆盖小文件和超大文件**：以真实 `FileTreeModel.swift`（382 行）为首要回归，再覆盖约 **1,000、10,000、100,000 行** Swift 代码，含真实代码长度／语法而非只有极短的重复行。十万行若超过现有 5 MiB 上限，应在容量、内存与本机／SSH 读取证据支持下调整限制，使其真正可打开、浏览及编辑；不能静默截断或取消安全的写入保护。
3. **按需排版与完整滚动范围并存**：不靠每滚动一屏同步排版全文，也不能锁死错误高度。借鉴 Zed 的 [ScrollAnchor](https://github.com/zed-industries/zed/blob/main/crates/editor/src/scroll.rs)、[DisplayMap／WrapMap](https://github.com/zed-industries/zed/blob/main/crates/editor/src/display_map/wrap_map.rs) 与[可见行布局](https://github.com/zed-industries/zed/blob/main/crates/editor/src/element.rs) 的责任分离；继续使用 Swift 6／AppKit／TextKit 2／SwiftUI，不移植 Rust／GPUI。无软换行时优先验证准确的稳定行高；软换行和可变高度必须按文本锚点保持阅读位置，不能凭猜测声称全篇高度无需计算即可精确。
4. **低 CPU、低内存的真实编辑**：在常见小修改和连续滚动热路径中，工作量应主要由修改范围／可见行决定，而不是随文件总字节或行数线性增长。避免每次按键提取／比较整文、重复生成解析快照或更新后续十万行坐标；只有真实保存／显式导出等完整内容消费者才可付出必要的全文成本。空闲时不得持续解析、布局或重画；多标签关闭后释放其独占缓冲、语法任务和视图。
5. 保持代码颜色、中文 IME、Undo、Find、选区、滚动恢复、软换行／不换行、行号、无障碍、字节保存及共享 Diff 行为。**字节级未保存判定**仍须在撤销或手动恢复原字节后准确清除；保存期间的新编辑不能被旧保存结果吞掉。采用新路径时在**同一个实施任务**删除被替代的旧逻辑、同步文档并验证，不保留无依据的补丁层。

## 明确不做

- 不把触控板事件处理或追求 120 FPS 当作默认方案；**滚动条范围和阅读位置正确优先于纯帧率**。不重写 Git、Files、Diff，也不重启已 [No-Go 的 Tree-sitter 插件迁移](../editor-git-performance/evidence-p7.md)。
- 不强制全篇 TextKit layout、不为小文件建立第二套缓冲或永久缓存、不先引入 Rope／SumTree／Metal 或新第三方依赖。仅当 10,000／100,000 行的真实采样证明现有增量索引仍随全文规模增长，才借鉴 Zed 的结构化索引思想并用 Swift 在原所有者处替换；不新建常驻诊断系统，不撤销输入、保存和 Diff 保护。
- 当前请求**只审查并修订计划**，不实施产品改动、不触碰并行 P6 工作区与用户正在运行的 Kero。

## 验收

- **382／1,000／10,000／100,000 行**：不软换行的固定行高场景连续上下滚动、拖动滑块和四分位跳转，`documentView.frame.height`／滑块长度不能反复跳变；软换行场景则检查视口文本锚点不跳、滚动范围连续和文末可达。读写／字号／宽度变化引起的合法高度修正单独验证。
- 大文件在明确资源预算内打开、首次可见文本、正确语法高亮、编辑／保存并可直接到达末尾；记录首次加载、稳定滚动、主线程耗时和内存，既不能被 5 MiB 限制悄悄拒绝，也不能用全文强制布局换稳定滑块。
- 另外测 **单字符输入／删除／撤销（文首、文中、文末）**在四档文件上的主线程时长中位数／p95、每次编辑全文提取与比较次数、内存分配／峰值、连续滚动 CPU、空闲 CPU 与唤醒、多标签打开及关闭后稳定内存。按同机同模式前后比较，避免用固定 FPS 数字或一次冷开耗时冒充总体性能；结果须明确实际字节数、是否软换行和 CPU／内存代价。
- 修改前后做真实界面观察与原生几何断言，使用 Instruments Time Profiler／Allocations（如工具链不可用则记录阻塞并用可用采样）定位剩余问题；`FPSCounter` 不代表实际编辑器帧率。执行后须通过受影响的 Editor／Diff、保存/Undo/IME 回归、`make test`／`make build` 和签名检查，遵守 [测试完成标准](../../../docs/testing.md)。
