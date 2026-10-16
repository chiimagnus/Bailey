# P2：按需后台加载与纯颜色样式

**目标：** 不在打开入口无界读文件，不让高亮制造无效字体事务。
**不做：** 新文件状态机、连接管理器、通用队列、图片新限额。
**前置／验收：** P1 基线；普通文本有界且可输入，非视图追加、rename、断线和保存正确，字体冗余事务消失。

每项分别验证／提交；共同完成标准见 [testing.md](../../../docs/testing.md#完成标准)，必要清理、测试和文档不延至 P6。

<a id="p2-t1"></a>
## P2-T1 统一按需加载、解码与断线只读

**根因：** Project.openFile/makeContent 同步构造 FileTab，本机 init 调 readImmediately(.max)，MainActor 解码后才检查上限；远端 init 和 onAppear 可重复读取。ignoreGitPaths 在 openFile 后立即 waitForText，因此不能把初读独占给 onAppear。

**文件／验证位置：**
- `kero/Editor/FileViewerView.swift`：FileTab init、waitForText、reload、loadedContent、updatePath 和视图触发。
- `kero/Workspace/LocalWorkspaceBackend.swift`：readImmediately/readSync/read；复用 WorkspaceBackend／SSHWorkspaceBackend。
- `kero/Editor/SourceTextEditor.swift` 的编辑资格；`Project.connectedWorkspace/rebindRemoteTabs/ignoreGitPaths`、`SSHHostWorkspaces.setConnected` 的既有目标／断线链。
- Vendor STTextView 的 AX setter／资格契约及 `DiffTextView` 现有保护；共同底层修复确有需要才纳入补丁。
- 扩展 FileTabTests、WorkspaceIdentityTests、PaneRetentionTests；backend 边界可加 `KeroTests/Integration/Files/WorkspaceReadTests.swift`，仍进现有 XCTest。核对全部受影响的直接 FileTab 构造测试，包括关闭／Git 保存，不能只迁移三类。
- 文档：`docs/features/editor.md`；连接事实改变同步 `docs/features/ssh.md`，Vendor 补丁变化同步 `docs/development.md`。

**步骤：**
1. Red：init 无消费者不读；挂载／waitForText 都能首次加载；真实 Project.ignoreGitPaths 在视图未挂载时保留原文并保存追加规则。保留等待消费者跟随同目标替换读取、拒绝换目标的契约，不能丢旧测试的有效覆盖。
2. init 只建身份与 .loading。同一按需入口服务视图和 waitForText，已在途首次加载不重复启动；真实外部变化重载不能被请求合并吞掉。无人消费的恢复标签保持懒加载。
3. 普通文本传 5 MiB，tooLarge／读取失败／编码失败分别表达。复用本地 @concurrent read/readSync 和远端有限读取；解码放明确后台数据入口，不为每 caller 包另一套 detached。NSImage 留正确隔离域。
4. 图片维持完整读取和现有扩展名策略，无效图片再回文本／二进制规则，不引入图片新上限，也不称全部读取有界。
5. loader 仍归 FileTab，复用 reloadGeneration／保存目标代次。loading 时 rename 要失效旧读取并从新路径继续；旧代次、dirty、断线不能发布。任务完成清对应句柄，旧任务不能清新句柄。只有证明 path/cancellation 与代次完全等价才删重复条件，不能机械删除数据保护。
6. 保存保留现有串行快照与原子 backend.write；失败／保存中输入不丢。保留 matches，未变内容不替换原生编辑器和撤销。
7. 固定 SSH host 的连接状态接入现有 Project 重绑，不新增全局 owner／探测循环。未知初连和显式读取仍能建立连接；已知断线保留预览／草稿并只读，面板刷新／选中／显式重试能重新读原机器，不能被只读永久锁死。检查 FileTab 与 DiffTab 两个消费者。断线闭环实际复现 Diff 读失效后 loading 不结束，因此把原 P5-T3 的加载失效公共拥有者修复提前到本 task：所有 reloadGeneration 失效统一结束该代次 loading，保留旧任务不能结束新任务的检查，并补输入、撤销后再读与断线回归。
8. 原生 isEditable 表达只读，选择／复制／查找保留。Vendor 的 setAccessibilityValue 当前直接写 text，不受 isEditable 保护；测试 AX 不可绕过。优先在共同原生写入所有者修复，并在同 task 删除 DiffTextView 被替代的重复守卫，不再加 View 层假只读。
9. 同 task 删除 readImmediately、同步 init 和 init 自动启动的第二条路径、无消费者 helper／旧说明。readSync 仍服务 async read，statSync/gitRootSync/isLinkedWorktreeSync 仍有真实同步消费者，不类推删除。
10. 受影响测试显式按需加载／等 .text 后编辑；fake 也遵守 maxBytes 超限抛错，不能 prefix 截断后冒充成功。不为旧测试保留同步兼容接口。

**验证：**
- `make test ONLY_TESTING=KeroTests/FileTabTests`；运行新增 WorkspaceReadTests 及上述受影响测试，再 `make test`、`make build`。
- 临时文件 0、cap−1／cap／cap+1、缺失、symlink；受控 rename／连接／延迟读取、追加、写入失败／期间输入、撤销核对真实磁盘。
- 原生键入／AX 替换尊重只读，重连后可写且 undo／内容保留。SSH 仅用专用获准 fixture，模拟不叫 E2E。
- 隔离 App 经树／菜单／恢复打开 512 KiB／4 MiB；等待时切终端、加载后编辑保存。复测读取次数、解码线程和可见延迟，明确图片例外。

**提交：** 加载、真实消费者、只读闭环、必要测试迁移／文档和替代路径删除一个原子结果；Vendor 修改按依赖规则验证文件与 Diff，不夹带升级。

<a id="p2-t2"></a>
## P2-T2 删除高亮无效字体事务

**根因：** theme.fonts 为空，coordinator 仍设置 font 为原 font；token 默认带 font，clearStyle 再写 font。Vendor setter 会全文加属性，不是无成本赋值。

**文件：** SyntaxHighlightPlugin.swift 的初始化／AttributeProvider／SyntaxHighlightTextInterface；核对 SyntaxHighlighting.theme、SourceTextEditor.apply。扩展 P1 的 SyntaxHighlightingTests；文档归 docs/features/editor.md。

1. 保留真实插件着色／清理前后文本、字体、dirty 和 undo 不变、换字体仍生效的绿色行为基线；用 trace 记录冗余字体事务，不为性能改动编造必然失败的行为断言。若新增直接约束样式输出的测试，须调用生产路径，不复制 provider。
2. 删除无条件 setter 与 token／clearStyle 的 font，只用颜色临时属性；删除无消费者的“其他样式写文本存储”支路，不为假想字体表留脚手架。
3. 保留 metadata 过滤、themeColor 别名／逐层回退、零范围保护与真实弱引用，不当作多余围栏删掉。
4. `make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests`、受影响 FileTab／DiffTab 及完整完成流程。隔离 App 查 TSX／继承／嵌入颜色、主题／字体、IME、替换／撤销／保存；trace 中冗余字体事务应消失，再比较实际可见等待。

**提交：** 样式、测试与必要文档独立提交，不顺手改 token 顺序、资源或布局。
