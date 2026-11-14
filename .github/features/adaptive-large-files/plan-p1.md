# P1：先测真实成本，再决定最小编辑器架构

**交付：** 一份可复测的 8／16／32／64 MiB 性能与行为基线，以及可实施的单一正文方案。
此阶段只做必要的测量与最小原生验证，**不解禁文件容量、不迁入 GB 实现**。
完整目标与不变量见 [需求](idea.md)。

## 为什么先验证

`crh` 的真实路径是：

`FileTab.readContent → WorkspaceBackend.read(Data) → TextFileEncoding.decode(String)`
→ `SourceTextEditor.makeScrollView → textView.text = file.text`
→ `NativeCodeTextView.processStorageEdit → FileTab.refreshDirtyState`
→ `FileTab.writeCurrentText → WorkspaceBackend.write(Data)`。

当前 `FileTab` 同时保留 `bufferedText`、`savedText` 和原生文本反向读取，
有 `nativeTextIsCurrent`、`nativeCodeUnitDelta`、`reversibleEdit` 等派生状态。
`NativeMeasuredLineWidths`、初始行索引和高亮解析仍可能扫描全文。
这使“仅把 8 MiB 改成 64 MiB”无法证明主线程、内存或状态正确。

[旧版研究](vscode-source-study.md)与备份 `back2026-11-14`（`867366cf`）提供三条教训：

- **不能照搬 GB 分页。** 返回 `nil`／跳过冷段落让 TextKit 2 同步布局反复重试，
  旧实验一度超过 10 GiB 内存；8 KiB 移动可见窗口只是隔离原型，未接入正式产品。
- **机制通过不等于产品通过。** 旧分支的 1 GiB 编解码、SSH 管道和 Diff 外存实验
  并未使正式 `FileTab` 解除 8 MiB 或正式 Diff 解除 5 MiB。
- **日常安全边界值得保留。** `24014251` 的局部 IME/Undo、
  `5f1024e0` 的私有原子暂存，以及备份 `c771a930` 的外部同大小／同时间戳改写回归
  说明保存基线、文件身份和失败保稿必须真实验证；不要求搬运整套实现。

## <a id="p1-t1"></a>P1-T1：测量当前原生链与 32／64 MiB 可行性

**入口：** `FileViewerView.swift`、`SourceTextEditor.swift`、`NativeCodeTextView.swift`、
`NativeTextLineIndex.swift`、`SyntaxHighlightConfiguration.swift`；
现有 `NativeEditorLayoutTests`、`FileTabPersistenceTests`、`NativePaneRetentionIntegrationTests`。

- 先执行当前 8 MiB 宿主基线，记录首次可交互、主线程最长阻塞、
  文首／文中／文末 30 次输入 p95、远距跳转、查找、保存耗时和增量峰值内存。
- 在**临时测试文件**与原生组件中测量 16／32／64 MiB 的合法 UTF-8，
  覆盖 10 万短行、长行、混合 CRLF／Unicode、折行与高亮。
  现有限制仍生效时，不把直接原生组件测试冒充 `FileTab` 的成功打开。
- 对比相同文件在首次挂载、重复挂载、A→B→A、关闭后释放的行为；
  定位超过预算的真实调用点，不根据文件大小猜瓶颈。
- 为 P2 固定明确预算：32 MiB 输入延迟建议门限 p95 ≤ 50 ms，
  不能有长时间的主线程独占；内存、打开时间与 64 MiB 门限按实测明确写入任务记录。
  若门限不合理，以机器、测量和可感知行为为依据修订，不能偷偷放宽来宣布通过。

**完成判据：** 有可复测的命令、测试文件构造方式、真实数字与峰值来源；
明确区分 8 MiB 产品基线、32／64 MiB 组件探索和正式 E2E。
产生的日志放现有测试产物目录，不增建永久研究目录。

## <a id="p1-t2"></a>P1-T2：选定单一正文所有者并完成最小真实原生验证

**入口：** `FileTab.text`／`savedText`／`refreshDirtyState`、
`SourceTextEditor.Coordinator.currentText`、`NativeCodeTextView.processStorageEdit`。

- 比较 **FileTab 持续拥有原生文本存储** 与 **FileTab 持有独立小文件正文**
  两种简单方案，按真实挂载／卸载、Undo 和保存行为选一种；
  一次只有一个权威可写正文，不允许两套镜像互相同步。
- 在**真实 FileTab + NSTextView** 测试最小跨行输入、IME 组合、
  多选区、退回保存点、背景保存中的新编辑、关闭释放；确认源、选区与 Undo 同步。
  避免脱离产品入口的 `NSString` 幻灯片式演示。
- 决定哪些原有入口直接沿用，哪些**随新链路接通而删除**：
  `bufferedText` 的往返镜像、字符频数脏状态、旧保存任务链等仅在有等价行为后退休。
  不顺手重写 Git 历史、Dock 或终端。
- 如果 32 MiB 的原生完整编辑必须引入 GB 级窗口模拟／第二编辑器才能达标，
  给出具体失败证据和更小可行范围，停止扩建并回到需求决策。

**完成判据：** 方案能由开发者用一张调用链说明，
有真实输入与保存的最小测试，以及将被取代的明确文件／符号清单；
不预留未证实的插件层、存储树或复杂跨端协议。

## 阶段验收

- **容量／文本：** 0、1、旧 5／8 MiB 附近、16／32／64 MiB，
  超限大小拒绝；超长无换行文本、10 万行、CRLF、BOM、中文／emoji／组合字符、NUL。
- **交互／生命周期：** 折行、字体大小、滚动、查找、多个原生选区、输入法组合、Undo、
  tab 切换／重挂载／关闭、多窗口和缓存释放；测量峰值而非只测打开成功。
- **环境：** 当前 macOS／Xcode 与最低部署目标 SDK；
  不创建 macOS 虚拟机，不在正式 Bailey 会话运行 GUI 自动化。
- **结果：** `make test:NativeEditorLayoutTests,FileTabPersistenceTests,NativePaneRetentionIntegrationTests`
  与真实原生组件测量；如测试入口命名改变先核对 Makefile。
  后端、GUI、真实 SSH 尚未测的条件不得计入阶段完成。

任何单项异常（崩溃、卡死、全文丢失、IME 错序）均先定位修复或明确 No-Go，
而非追加更多兜底框架或把 64 MiB 变成下一项必须交付的架构负担。
