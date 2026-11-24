# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：原生编辑、Undo 与有版本保存已有真实字节证据；断线保存恢复专项已通过（443168ca），完整宿主回归待验。非协作外部写入的最终校验／发布竞态与完整 App 验收未核销。

## 任务与改动

- **P2-T1 对原文源区间执行原生编辑、复用唯一 Undo**：FileTab、原生表格与 TextKit 共用文档和 Undo；100001 条记录、100 次编辑／切换和 Undo／Redo 有宿主证据，完整 App 的中文 IME、快捷键与 GUI 性能待验。
- **P2-T2 严格往返编码、条件保存和外部冲突**：FileTab、DiffTab、TextFileEncoding、WorkspaceFileVersion 共用原字节版本和提交确认；重连保留在途快照，不盲目重复写入。

## 发现项

## 发现 F-02

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Open`
- 位置：`Bailey/Workspace/LocalWorkspaceBackend.swift:279; Bailey/Remote/RemoteCommands.swift:331-336`
- 摘要：`非协作第三方可在最终版本检查与替换之间发布新版本；本机与 Windows 已实测`
- 风险：`并发外部内容可能被静默覆盖`
- 预期修复：`必须在共享写入所有者使用经实际验证的条件原子提交，或明确批准且保留各冲突版本的替代产品契约；不新增 CSV 保存器、不重复校验冒充 CAS`
- 验证：`受控屏障注入真实外部写入；核对磁盘、双方完整字节、保存错误、原生草稿、重新打开及共享旁车路径`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-01

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/FileViewerView.swift:1152; Bailey/Git/DiffViewerView.swift:1150`
- 摘要：`文件或可写 Diff 的写入已提交但旧 SSH 通道失效时，丢弃待确认的保存快照，重连后仍以过期原字节版本保存；在途撤销至旧基线也可能被误判为 clean`
- 风险：`后续合法草稿无法保存；干净刷新、关闭或文件变更可能误判未确认的保存意图`
- 预期修复：`保留当前文档唯一在途文本提交快照及其版本，按当前同机连接只读核对实际已发布／原始／冲突状态；仅确认实际发布才推进基线，不重试不确定的写入，不引入 CSV 专用保存器；共用字节确认及传输错误分类`
- 验证：`真实原生网格 UTF-8 BOM 编辑→断线后成功发布→同机重连→再次编辑/保存；在途 Undo、编码转换及第三方冲突；可写 Diff 原生正文同序列，保持实际字节与所有者`
- 解决证据：`443168ca：旧实现3项Red/14失败断言；最终FileTabPersistenceTests 77/77、Diff拆分专项7/7、真实Windows CSV断线回执丢失和同机重连通过；原始UTF-8 BOM、混合行尾、中文、后续字段编辑、本机同路径隔离、在途Undo和未发布编码转换实际字节及草稿断言通过。三个Diff专项各同进程重复10轮无失败；Release、Dev严格验签通过。初轮联合测试出现Undo事件分组失败，后一次长异步用例在XCTestCore/Swift Concurrency运行时崩溃，拆分用例后复验通过，保留日志和全量复验门禁。日志 /tmp/bailey-seven-text-recovery-red-20261125.log、/tmp/bailey-seven-publication-filter-recheck-20261125.log、/tmp/bailey-seven-diff-recovery-split-20261125.log、/tmp/bailey-seven-recovery-filter-repeat-20261125.log。`


## 验证与未覆盖

- 冻结 `3f87e2e8` 完整 Host 1406/1406、无跳过，Dev 严格验签通过；不覆盖之后的保存恢复改动。
- 100001 条记录、100 次编辑与 Undo／Redo、UTF-8 BOM、混合行尾、宽 Unicode 及未改字段的原字节证据见 todo.toml；实体输入、跨窗口及真实完整 App 组合仍未验收。
- C12×C13：本机和 Windows 实测非协作第三方可在最后校验与 rename 之间写入。协作锁、RENAME_SWAP、File.Replace 都不能证明任意第三方的严格 CAS；不将其视作通过。
- 现行保存机制见 `docs/features/editor.md` 与 `docs/features/ssh.md`；待提交与最终复验。

