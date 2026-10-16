# Audit P3 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 补齐编辑后的高亮范围更新
- [x] P3-T2 恢复字节精确文本契约并删除重复比较
- [x] P3-T3 验证并收敛坐标扫描热点
- [x] P3-T4 验证并优化根解析调度
- [x] P3-T5 修复查询失败闭环并按需共享编译
- [x] P3-T6 验证嵌入语言复用方案
- [x] P3-T7 接入已验证的子区域复用措施
- [x] P3-T8 修复原生组合输入结束时丢字
- [x] P3-T9 核实解析输入分块边界并按实证修复
- [x] P3-T10 修复解析队列失效范围的旧坐标交付
- [x] P3-T11 清理插件依赖与无用主题包装
- [x] P3-T12 修复长文档反向定位的视口错误

## 任务到文件的映射

- P3-T1
  - `kero/Editor/SyntaxHighlightPlugin.swift`；`SyntaxHighlightingTests`；`docs/features/editor.md`
- P3-T2
  - `SourceTextEditor.swift`、`FileViewerView.swift`、`DiffViewerView.swift`、`DiffEngine.swift`；FileTab／DiffTab／DiffEngine 回归；editor.md／diff.md
- P3-T3
  - `TextCoordinateIndex.swift`、coordinator 接入；固定 seed 与真实 Parser 对照
- P3-T4
  - `SyntaxHighlightPlugin.swift` 初始化阈值；原生输入与关闭释放回归
- P3-T5
  - `HighlightQueryCache` 与 root／embedded／`DiffSyntaxHighlighter`；`HighlightQueryCacheTests`
- P3-T6
  - 本地 `evidence-p3.md` 与 build/performance 下原型／sample；未提交原型
- P3-T7
  - `SyntaxHighlightPlugin.swift` 当前 revision 的 NamedRange→Task、裁剪和失效；真实围栏／HTML／释放回归
- P3-T8
  - `Vendor/STTextView/.../STTextView+NSTextInputClient.swift`；`EditorTextInputTests` 与系统 NSTextView 对照
- P3-T9
  - `SyntaxHighlightingTests` Unicode 分块／TextKit 快照对照；未新增 reader
- P3-T10
  - `Vendor/Neon` 核心、Xcode 同身份本地覆盖、许可证资源；连续排队编辑真实最终颜色回归
- P3-T11
  - 四处应用 import、SyntaxHighlighting 颜色字典、Package.resolved；主题等价性与唯一包图
- P3-T12
  - `Vendor/STTextView/.../STTextView+Scrolling.swift`；`EditorNavigationTests`；development.md／editor.md／testing.md

## 发现项

本轮独立沿生产入口复核，未发现需要新增修复的确定性缺陷。没有借用旧 audit 的结论。

## 修复日志

- 无新增修复。已复现的旧坐标、IME、围栏旧色、反向定位已在所属任务修复并留下永久回归，不重复记作未解决项。
- 核对实际 delegate proxy：will／did 的 replacementString 非可选，插件事件的可选闭包签名不能作为新增空输入围栏的依据。
- 用户允许恢复 Xcode GUI 自动格式重排后，只恢复 project.pbxproj 到当前 HEAD；新本地包引用保留。

## 验证日志

- `make test`：最终 P3 280 tests、0 failures、3 专用 SSH skipped（p3-t12-test.log）。
- 76 项联合定向通过；Debug／Release 构建和严格整包验签通过。恢复工程格式后 `make build` 再通过（p3-restored-project-build.log）。均使用 Xcode beta。
- 正常路径及实际边界：原生当前 AST／颜色、NFC→NFD 实际写盘与 Git、连续编辑和 undo／redo、未知／删除围栏、取消首个编译等待者、关文档释放、远距离前后定位实际几何。
- 源码复核到 FileTab／DiffTab 的序列写盘、编辑期基线保留、Neon 队列和谓词版本校验、TextSystemInterface 实际 rendering attributes、TextKit 定位副作用；不存在新旧解析器双轨。
- 当前文档归属、事实、导航及补丁表已随提交更新；远程资源包仍存在且只有一个本地 Neon 运行时，未冒称完整去包。性能数字区分 provider、原生定位和完整 App。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：当前阶段的正确性与采用优化均有针对性验证，未发现阻止 Git 阶段推进的确定性问题。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余边界：不是独立 App 键盘／绘制 E2E；Instruments 被 beta 系统签名限制阻塞，采用 sample 与原生计时，不宣称 Allocations／RSS 已验收。长行 TextKit 成本仍在；SSH 无本次专用主机，3 项跳过。完整 App 综合路径与安装留 P6，不把组件数字当整机收益。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

