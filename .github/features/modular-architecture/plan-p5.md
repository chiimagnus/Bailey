# P5：交叉核对与最终真实验收

**Goal：** 确认 P1–P4 的代码与文档在最终目录下真实一致，验证关键行为，没有遗漏旧实现、额外协议或无用的历史兼容分支。

**Non-goals：** 不在最后阶段集中大拆代码，不再创建新的服务/协议/测试平台，不新增 `docs/ARCHITECTURE.md` 重复根 `AGENTS.md` 的架构契约。

**Approach：** 旧定义/旧路径/过时兼容必须在每个实现 Task 就地删除；本阶段只做全局交叉检查、修正遗漏的文档链接及真实环境验收。发现具体遗留代码时退回责任 Task 修复并重新验收，不创建 P5 “垃圾清理大提交”。

**Acceptance：** 目录/引用真实可达，`AGENTS.md` 与 `docs/CONTRIBUTING.md` 仍是唯一规则/验收归属；没有残留无用代码、向后兼容分支、重复树/标签组件；签名 Debug 的工作区、文件、Git、Info 与本地/SSH 不退化。

**Rules：** 保护正在运行的 Shell、未保存文件、用户 Git 资源和当前快照；不把真实输入校验、错误处理、SSH 主机信任、Git 丢弃确认或当前恢复分支当成“多余安全围栏”。

---

<a id="p5-t1"></a>
## P5-T1 全仓调用链、旧路径和文档交叉核销

**Files / 核对范围：** 当前 `kero/App/`、`Workspace/`、`Terminal/`、`Files/`、`Git/`、`Info/`、`Remote/`、`Editor/`、`Browser/`、`UI/`、`Shared/Tree/` 的实际源码；`AGENTS.md`、`docs/CONTRIBUTING.md`、`docs/PRODUCT.md`、`docs/DEPENDENCIES.md`、`docs/PERFORMANCE.md`、相关产品指南及 `scripts/check-*.swift`。

**核对：**
1. CodeGraph 和实际调用搜索确认 `App` 负责组装、`Workspace` 负责项目/窗口/两层布局，`Terminal` 负责 Shell/Ghostty，Files/Git/Info 仅一套模型/操作/UI；`Shared/Tree` 被所有三类树区域共用。明确 `BrowserView`、`DiffViewerView` 的大文件虽然包含同功能的状态和渲染，不按行数增拆。
2. 检查旧 `Workspace/TreeDisplayModel.swift`、`UI/Panels/TreeRowStyle.swift`、`Workspace/FileTreeModel.swift`、`Terminal/SessionInfoModel.swift`、`UI/Panes/Panes.swift`、`Terminal/TerminalManager.swift` 与 ToolPanel 旧视图定义是否都已在责任 Task 删除；检索旧 `SessionStore` 列式/单窗口分支、`AppSettings.legacyDefaults`、`WorkspaceBackend` 类型扩展与原 Git runner。
3. 更新残留的真实命令/Markdown 链接/源码锚点；必要时修正 `AGENTS.md` 中已完成的状态描述。不新建重复“架构总览”文档，不保留原路径假文件充数。
4. 发现遗留具体代码返回其归属 Task 清理并独立验证；P5 仅可能对遗漏文档路径做最小单独提交。

**验证：** 本地链接逐条存在；CodeGraph 与 `rg` 没有旧引用、重复定义和无用未消费协议；Xcode 源文件同步接入，三项独立检查实际编译并运行，Debug 构建/签名通过。不能把零搜索结果当成所有功能已实测，`git diff --check` 通过。

**提交边界：** 只有实际文档或遗留错误的修正才提交；若无需修改不制造提交。

---

<a id="p5-t2"></a>
## P5-T2 安全替换签名 Debug 并验证核心工作流

**真实路径：** `kero/App/keroApp.swift::WindowRootView`、`Workspace/TerminalManager`（P3 后）、`SessionStore/TerminalHistoryStore`、`WorkspaceDockView`、`PaneLayoutView`、Files/Git/Info 与各本地/SSH backend；验证规范 `docs/CONTRIBUTING.md`。

**执行：**
1. 先确认真实 Kero 正在运行什么命令/有无未保存编辑、Git 工作树和用户快照；只在安全时正常退出/替换正式包。不能停止的 Shell 存在时，先用同一个签名 Debug 的 `--isolated-ui-test` 测试，不强退当前进程，也不让隔离实例覆盖正式快照/转发。
2. 与本轮执行前基线比对本地与可安全连接的 SSH：新建/切换项目、外层 Dock 跨组排序/分屏/关闭、内部 `PaneNode` 嵌套、窗口恢复、现用布局快照、终端未被意外重启；文件和编辑器未保存状态正确。
3. Files 与 Git 的三种共享树状态/交互；在单独测试仓库进行 Git 状态、暂存/取消/丢弃、分支和 Diff；Info 本地及安全可达的远端进程/端口，SSH 转发打开→切走→回来→取消和断线；确认切换范围后旧异步结果不能错写。
4. 检查正式项目/标签恢复及签名、三项 `check-*.swift` 的新源码路径、旧定义零重复；清理测试输出、隔离配置/历史和安装临时包，不删除用户快照或其他项目。无法实际验收的 SSH 条件如实列明，不以构建/点击成功冒充实机通过。

**验证：** 受影响功能全部报告明确通过或未验证，来源是实测/代码回归而非猜测；记录原子提交与对应任务的实现状态，确认只剩当前 Feature 授权保留的文件。出现缺陷回对应 Task 修复，不以 P5 的附加保护逻辑掩盖根因。

**提交边界：** 实际验收无需生成新的功能提交；若修复具体失败，提交到其归属 Task 并重新验收。

---

## 完成条件

最后一步仅完成跨模块一致性与用户可见行为验证，不把遗留代码堆积到本阶段才统一清理。所有 Phase 实际完成之后才按工作流生成相应审计文件，本次计划审查不读取已有 `audit*.md`。
