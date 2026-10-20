# P4：外部变更集成与跨功能最终验收

**Goal：** 让新多选、隐藏、过滤、`⌘P` 索引、Reveal 和文件操作在现有外部文件变更链路下保持一致；联合 #40 完成 F6 的真实用户验收。

**Non-goals：** 不在 #5 再实现 macOS FSEvents 事件监听／SSH 通知／定时器替换，不擅自改 #40 的 Go／No-Go 结论、不为追求“无轮询”引入远端 Server 或守护进程。

**Approach：** 当前 `ToolPanelView.syncModels → Project.syncFiles → FileTreeModel.sync` 在 Files 可见时每 2 秒刷新，终端命令完成／前台恢复也可触发。#40 的 `plan-p1.md` 已承担本机 Files FSEvents，`plan-p2.md` 已承担远端临时通知的可行性与条件实现。此阶段只在**现有 FileTreeModel／ProjectFileIndex 状态所有者**接入缓存失效、选中清理及索引更新，并对 #40 产出的实际刷新来源做集成测量；不能从 FileManager／Git 数据推断另一个后端的结果。

**Acceptance：** 外部创建／移动／删除／分支切换使 Files 可见状态、选中、过滤／Reveal 及 `⌘P` 结果与真实目录一致；空闲不会因新功能增加重复 IO；无法实现的 SSH 原生通知保留 #40 已确认的轮询回退。#40 未完成前，F6 验收必须明确保持未完成。

**Rules：** 真正的文件事件与读取完成是不同边界；最终以磁盘／远端真实目录为准。事件丢失补偿、根 watcher 生命周期和远端取消属于 #40；不复刻其任务、测试夹具或配置。每个 #5 实现 task 已完成自身 TDD／文档，此阶段只负责跨功能联动和最终系统组合。

---

<a id="p4-t1"></a>
## P4-T1 外部更新后的选择／过滤／搜索索引一致性

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift`（`syncModels`、`performSync`、`PanelSyncQueue`、`commandCompletionSequences`）、`Bailey/Workspace/Project.swift.syncFiles`、`Bailey/Files/FileTreeModel.swift`（`sync`、`rebuild(refresh:)`、`cachedDirectories`、现有及 P1/P3 新选择／隐藏／过滤状态）、`Bailey/Workspace/ProjectFileIndex.swift`（P3 共用索引）、`Bailey/UI/CommandPaletteView.swift`（`indexedTarget`、取消与查询），以及 #40 的 `GitFileEventWatcher` 及监听结果接口（仅消费，不重复创建）。

1. **Red：** 在独立 CLI／Finder／Git 进程中真实新建、重命名、移动、删除文件和切换分支，同时保持 Files、过滤文本、部分多选和 `⌘P` 打开；核对当前版本已支持哪种触发（2 秒轮询或终端命令完成）、哪一种内容没有重查索引。用受控阻塞后端制造“扫描启动→外部改名→旧响应迟到→切项目”的真实时序，断言最终不保留失效选中、不将旧索引提供为可点击文件。
2. **Green：** 文件树成功发布**已确认的当前目标目录变化**时，按需使当前可见过滤／文件索引失效和重算；当前仍存在的选中按真实路径保留、消失的清除、已知成功移动的使用 P1 路径映射；不因未变更目录或 SSH 读取失败抹除有效树。新索引失效直接接 P3 的唯一索引缓存／取消通道，不每次触发整棵树和全量 SSH 搜索。#40 发布本机事件驱动时复用其现有事件到 `Project.syncFiles` 路径；远端若 No-Go，仍需通过实际 2 秒读取最终内容，且不增加额外 SSH 请求。
3. **验证：** 本机 Finder、外部编辑器与独立 CLI（不是 Bailey 自己的动作），普通目录与 Git Worktree、检出切分支、原子替换、重命名/跨目录移动、软链接与压缩链、缓存未加载／已加载、Files 前后台切换、等待中的读／写／索引任务、两窗口和同名跨机器项目、SSH 超时／失败／重连、批量数百次突发更新。逐项记录**触发来源、真实目录内容、Files 行、选择集、过滤结果、`⌘P` 路径**，测空闲及变化下的读取次数、CPU、RSS 和 UI 重绘；使用 `FileTreeTests`、`PanelContextTests`、`ProjectFileIndexTests`、`GitExternalRefreshTests` 及真实 GUI／受控 SSH。
4. **文档与完成：** 此 task 只更新因新功能确实变化的 `docs/features/files.md`、`command-palette.md`、`docs/testing.md`；监听器所有权及 SSH 通知决策留给 #40 文档，不写冲突版本。与同次测试一并独立中文提交。

---

<a id="p4-t2"></a>
## P4-T2 全入口极端组合 E2E 与 #40 F6 验收对接

**源码与测试锚点：** `Bailey/Files/{FileTreeModel,FileTreePanel}.swift`、`Bailey/Shared/Tree/{TreeDisplayModel,TreeRowStyle}.swift`、`Bailey/UI/{CommandPaletteView,Panels/ToolPanelView}.swift`、`Bailey/Workspace/{Project,TerminalManager,ProjectFileIndex,WorkspaceBackend}.swift`、`Bailey/App/{BaileyApp,AppSettings}.swift`、`Bailey/Remote/SSHWorkspaceBackend.swift`、`Bailey/Editor/FileViewerView.swift`。对应 `BaileyTests/Integration/Files`、`BaileyTests/Integration/Workspace`、`BaileyTests/NativeUI`、`BaileyTests/WorkspaceUI`；#40 状态以其 `todo.toml` 和可复验的代码／证据为准。

1. **建立环境和覆盖账本：** 确认目标仓库与授权的临时文件夹／SSH 临时测试根、macOS 15.6+ 可用设备、Swift 6 / Debug 正式 UI 隔离方式，以及每项测试的实际前置条件。按 `idea.md` 的**全集**展开为实际执行记录，覆盖环境、正常／异常／极端输入与有成本限制的组合；每个可获得且可安全执行的条件都要测，不能只挑代表场景。测试不能写入正式工程文件或借用用户 SSH master，也不关闭当前用户使用的 Bailey。
2. **真实系统主线：** 以临时项目执行完整路径：多选／剪切／复制／粘贴／副本／批量删除（本机 Trash、SSH 确认），目录和单文件移动后编辑器继续编辑、Undo、保存；内部拖放默认移动和 Option 复制、Finder 外部拷贝及 Projects／Dock 其它意图；配置隐藏、临时显示、深层 Files 过滤、Reveal、Cmd+P 本机／SSH；外部 CLI/Finder/Git 更新并再次操作。每条覆盖明暗、中英、窄/宽面板、键盘/鼠标、同机跨项目／跨窗口、不同机器同名路径、1000+ 文件、Unicode/链接/目录压缩、错误 Sheet 与数据完整性。不能用单元 Mock 或 App 未实际运行的检查代替 E2E。
3. **极端竞争和资源：** 用可控阻塞和真实 OS 操作复核：复制中目标被抢占、剪切后源消失、改名/移动与 FileTab 旧写重叠、Git 检出同时搜索／拖放、窗口关闭/恢复期间 SSH 失联/重连、索引取消仍有迟到消息、重复触发相同外部变化；比较源/目标字节、已打开缓冲/Undo、SSH 请求数、目录扫描数、Git Graph 与底栏不闪烁、内存、CPU 和 watcher 释放。全部已识别边界逐项执行，超过笛卡尔组合预算时记录覆盖面并对已知失效组合做多因素交叉。
4. **#40 边界与完成门槛：** 独立核对 #40 当前真正已完成的任务和同环境证据：本机是否已删除旧 2 秒 Files 目录轮询，SSH Files/Git 事件方案实测 Go 才替换轮询，No-Go 则保持 2/5 秒可靠回退；不能把 `#5` 的轮询正确性说成 `#40` 的事件化已完成。#40 如果仍待验，标明 F6 整体联动**未结案**，但已完成且独立验证的 F1–F4 可单独汇报。不得替 #40 创建额外 watcher、远程服务、任务状态或审计。
5. **验证、文档与清理：** 所有相应 `ONLY_TESTING` 定向测试先独立通过，再运行 `make test`、`make build`、`codesign --verify --deep --strict` 检查及当前许可的原生 Debug App GUI；核对完整命令退出状态，CI 与本地结果不互相冒充。按 `docs/testing.md` 记录环境、提交、命令、测试数、真实 GUI/磁盘/SSH 证据、性能与每项无法实测条件的限制、替代证据、影响及补验，必要的文件 UI / Settings / SSH / Command Palette 文档于对应改动同次同步。只清理本功能替代的代码和自己生成的测试资源，不动 README、其它计划或用户工作区；独立中文提交验证相关变更。

---

## Phase Audit

全部实际实施后用计划工具生成 `audit-p4.md`，按真实任务、提交和最终磁盘／SSH／GUI 结果独立审查。只有 #5 的各项验收以及 #40 相关 F6 的实际证据都齐全，才能宣布 Issue #5 的全部范围完成；否则明确留下受约束项与补验条件。
