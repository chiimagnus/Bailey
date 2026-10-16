# P7：Tree-sitter 插件隔离对照（进行中）

本文件记录真实实验事实；Gate 未通过之前不更换 Kero 的正式依赖和运行中的 Debug App。实验目录：`build/performance/editor-git-20261016/plugin-treesitter-compare/`，只使用其独立 SwiftPM 构建产物。

## 当前完成的静态检查

- 官方候选 [STTextView-Plugin-TreeSitter](https://github.com/krzyzanowskim/STTextView-Plugin-TreeSitter) 实验修订 `346bbce977ce6a485ff9ad5696bebbe8790241e9`；SwiftPM 从 STTextView 2.4.0 起依赖，支持 SwiftTreeSitter 0.25，产品依赖的 `TreeSitterResource` 引用 38 个语法 target 和相应 38 个查询资源 target。候选源目录下载约 257 MB **不是安装体积**。
- Kero 当前 `Vendor/STTextView` 基于 2.3.11，仍有真实 IME、滚动、只读等本地补丁；当前源映射主要向现有 20 语言 + TSX 暴露功能，不因候选多语言自动改变映射。
- 候选 `Coordinator.updateViewportRange` 每次变化请求 `requestInitialHighlighting`，最终调用 `TreeSitterClient.resetDocument`；这是已确认源码路径，不是已经执行的完整 App 滚动基准。
- 候选包自身现仅发现 `TreeSitterClientTests` 一组 2 项，不足以证明真实 Kero 的注入语法、滚动、输入和 Diff 路径。

## 已运行的隔离检查

1. `upstream-test.log`：候选 Debug 包从源码全量构建完成（约 71 秒，隔离构建，非 Kero 项目构建），上游 2 项 XCTest 通过。
2. `kero-isolated-comparison.log`：增加仅在忽略的隔离目录存在的 3 项测试。Swift／TypeScript／TSX／Rust／Markdown 各语法能返回范围合法的 capture；30 次文首插入后的增量结果范围合法；同一 93,000 UTF-16 单元 Swift 文本 reset 8 次。Debug 3/3 通过，reset 中位约 318.1 ms。
3. `kero-release-comparison.log`：相同 3 项隔离 XCTest 在 Release 下 3/3 通过（包构建约 66.8 秒），reset 8 次中位约 63.4 ms、最差约 64.2 ms。**注意并非与现行 Kero 相同条件的滚动性能对照**。
4. 当前短样本捕获类型：Swift 11 个、Rust 9 个、Markdown 15 个；TypeScript 仅 1 个 `type.builtin`，TSX 仅 2 个 `keyword`／`type`，目前不能证明用户可见语法颜色等价；正式 Gate 需真实 JSX／注释／字符串及嵌入语言逐项验证。
5. 正式 Release 包当前 `build/DerivedData/Build/Products/Release/Kero.app` 约 84 MiB、安装的 Debug `/Applications/Kero.app` 约 95 MiB；Release Mach-O 带 `__LLVM_COV` 约 18.7 MiB 和约 2.0 MiB 的覆盖率数据。需要禁用／固定相同插桩口径才能对比新插件的体积。独立包 `.build/out/Products/Release` 约 138 MB **不是 Kero.app 体积**。
6. 用户提出 `build/DerivedData` Finder 显示约 48 GB；2026-10-16 同机 `du -sh build/DerivedData` 实测约 3.4 GiB、整个 `build/` 约 7.7 GiB，Finder 差异尚未解释。实际 Debug App 身份通过 `kero.debug.dylib` 核对；未清理共享构建缓存、不退出或重启用户 Kero。

7. 单独比对候选 Release 编译产物的解析器目标：相对于当前 20 语法加 TSX，候选新增 17 种；这些新增解析器的 C `parser.o`／`scanner.o` 中 `__text + __const + __data` 原始 section 载荷合计约 **15.03 MiB**，对应 object 文件总大小约 **18.2 MB**。这只是链接前的目标文件静态对照，不是最终 App 的增量；链接器去重／裁剪、查询 bundle、覆盖率插桩及其他代码都会影响实际安装包。

## 当前结论及待验证 Gate

候选能编译并解析代表语言，**未证明可无回归替换 Neon**。需按计划 P7-T1 做同条件旧／新原生捕获与颜色、Markdown／HTML 注入、长文件双向滚动／连续输入、关闭释放、实际 App 体积和 STTextView 版本兼容 A/B；确认所有门槛后才讨论实施 P7-T2。现在既没有切换正式工程，也没有减小 Kero App 体积。
