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

**验证：** 本地链接逐条存在；CodeGraph 与 `rg` 没有旧引用、重复定义和无用未消费协议；Xcode 源文件同步接入，原三项及责任任务新增的轻量回归实际编译并运行，Debug 构建/签名通过。当前工程使用 `PBXFileSystemSynchronizedRootGroup`，`kero/` 下 Swift 源码自动接入，只有 Info.plist 有排除；不为每次移动手写 pbxproj 文件列表。不能把零搜索结果当成所有功能已实测，`git diff --check` 通过。

**提交边界：** 只有实际文档或遗留错误的修正才提交；若无需修改不制造提交。

---

<a id="p5-t2"></a>
## P5-T2 安全替换签名 Debug 并验证核心工作流

**真实路径：** `kero/App/keroApp.swift::WindowRootView`、`Workspace/TerminalManager`（P3 后）、`SessionStore/TerminalHistoryStore`、`WorkspaceDockView`、`PaneLayoutView`、Files/Git/Info 与各本地/SSH backend；验证规范 `docs/CONTRIBUTING.md`。

**执行：**
本次用户授权已明确改为独立 `Kero Test` / `sh.kero.test`：只复制、签名和替换测试包，正式 Kero 及其现有 Shell 不操作。下文正式安装要求仅适用于用户授权正式替换的任务，不把本次未替换正式包记成遗漏；仍需实际签名包验收和保护现有隔离项目/历史。
1. 先确认真实 Kero 正在运行什么命令/有无未保存编辑、Git 工作树和用户快照；只在安全时正常退出/替换正式包。不能停止的 Shell 存在时，先用同一个签名 Debug 的 `--isolated-ui-test` 测试，不强退当前进程，也不让隔离实例覆盖正式快照/转发。隔离模式只隔离会话快照/历史并跳过长期隧道启动，**AppSettings、语言与 Diff 偏好仍共享**；不在隔离实例改用户设置/保存 tunnels.toml，不把它写成配置沙盒。不能安全替换时保留正式安装验收未完成的状态。
2. 与本轮执行前基线比对本地与可安全连接的 SSH：新建/切换项目、外层 Dock 跨组排序/分屏/关闭、内部 `PaneNode` 嵌套、窗口恢复、现用布局快照、终端未被意外重启；File/Diff 的未保存内容、编辑器查找/替换与光标/滚动恢复正确，Browser 的页面/历史/表单不因重挂载丢失。还需核对菜单/快捷键、Ctrl-Tab 与查找返回焦点、Finder 服务和通知寻址，不能只验证新目录能构建。
3. Files 与 Git 的工作区/暂存区/提交历史共享树状态和交互；在单独测试仓库进行 Git 状态、暂存/取消暂存/丢弃、分支和 Diff，检查最终文件/索引。Info 本地及安全可达的远端进程/端口，SSH 会话转发打开/复制→切走→关闭重开 Info→回来→退出交互 SSH；没有会话转发取消 UI，不增加它。临时网络失联和退出 master 的监听结果分开记录。长期隧道使用独立 TunnelManager，不能拿它代替会话转发验收，也不为验证自动修改用户隧道规则。确认切换范围后旧异步结果/旧进程行不能错写或向另一台机器发操作。
4. 检查正式项目/标签恢复及签名、全部受影响 `check-*.swift` 的新源码路径、旧定义零重复；只清理本轮生成的临时仓库/包和本轮可识别的隔离快照/历史，不清空 build、UserDefaults 或用户已有隔离数据。无法实际验收的 SSH 条件如实列明，不以构建/点击成功冒充实机通过。

**验证：** 受影响功能全部报告明确通过或未验证，来源是实测/代码回归而非猜测；记录原子提交与对应任务的实现状态，确认只剩当前 Feature 授权保留的文件。出现缺陷回对应 Task 修复，不以 P5 的附加保护逻辑掩盖根因。

**提交边界：** 实际验收无需生成新的功能提交；若修复具体失败，提交到其归属 Task 并重新验收。

---

## 完成条件

最后一步仅完成跨模块一致性与用户可见行为验证，不把遗留代码堆积到本阶段才统一清理。**每个 Phase 完成后立即进入该 Phase 的 plan-task-auditor，取得 Gate 后再执行下一 Phase**，不是做完 P5 才集中审计。审计文件只在实际进入相应阶段审计时创建/维护；本次执行前审查不读取已有 `audit*.md`，也不把计划修正标成代码已修复。
