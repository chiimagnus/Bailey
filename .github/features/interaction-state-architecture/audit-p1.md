# Audit P1 - interaction-state-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/interaction-state-architecture/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 修正不连续选择的锚点范围扩选
- [x] P1-T2 树刷新与折叠保持稳定身份
- [x] P1-T3 统一紧凑目录分段与命中区域
- [x] P1-T4 对齐共享树行视觉与无障碍状态
- [x] P1-T5 统一树键盘焦点与原生输入交接

## 任务到文件的映射

- P1-T1：`Bailey/Files/FileTreeModel.swift`（selectRange／moveSelection）、
  `BaileyTests/Files/FileTreeTests.swift`、`BaileyUITests/Files/WorkspaceFilesUITests.swift`、
  `docs/features/files.md`；提交 `2d23de91`。
- P1-T2：`FileTreeModel.swift`（sync／rebuild／remapPaths）、
  `BaileyTests/Files/{FileTreeTests,SSHFileTreeLiveTests}.swift`、
  `docs/features/files.md`；提交 `209ce031`。
- P1-T3：`Bailey/Shared/Tree/TreeRowStyle.swift`（TreeCompactSegment）、
  `Bailey/Files/FileTreePanel.swift`、`Bailey/Git/{GitPanel,RecentCommitsView}.swift`、
  `BaileyUITests/Files/SharedTreeUITests.swift`、`docs/features/{files,git}.md`；
  提交 `7fc68f08`。
- P1-T4：`TreeRowStyle.swift`（RowHighlightStyle／TreeFileRow／TreeFolderRow）、
  `FileTreePanel.swift`、`GitPanel.swift`、`BaileyTests/Files/FileTreeTests.swift`、
  `BaileyUITests/Git/GitChangesUITests.swift`、`docs/ui.md`；
  提交 `eed33ff7`。
- P1-T5：`FileTreePanel.swift`（FileTreeScrollView）、
  `TreeRowStyle.swift`（TreeKeyboardHost）、`FileTreeTests.swift`、
  `WorkspaceFilesUITests.swift`、`docs/features/files.md`；
  提交 `2af17ba`。

## 发现项

- 本轮源码、真实宿主与 GUI 审查未发现满足准入门槛的新问题；
  已知设备及最低系统验收缺口列于下方，不以猜测新增 finding。

## 修复日志

- P1-T5 执行期间已通过实际 Red→Green 修复重挂载的旧原生键盘宿主
  覆盖新所有权问题：删除 `updateNSView` 重复登记，保留
  `makeNSView` 唯一登记；对应提交 `2af17ba`。
- 审计未新增修复或抽象，现有五个任务提交均保留，
  没有向 P2/P3/P4/P5 扩大范围。

## 验证日志

- P1-T1：`make test:FileTreeTests` **84/0**，
  以及真实修饰键与右键 GUI **1/0**；6 行全部 64 种 Selection
  ×6 Anchor×6 Target，前后方向与实际复制字节；见 `evidence-p1.md#p1-t1`。
- P1-T2：`make test:FileTreeTests,PanelContextTests` **103/0**，
  获授权的真实 Windows SSH **3/0（0 skipped）**，隐藏／Reveal GUI **1/0**；
  验证同根重连失败保留、晚到结果隔离、1000+／Unicode、
  删除折叠路径与真实文件操作；见 `evidence-p1.md#p1-t2`。
- P1-T3：`make test:FileTreeTests,GitGraphPaletteTests` **90/0**，
  三类 Git 树与 Files 压缩路径 GUI **4/0**；
  精确分段右键、复制、stage、根目录与真实 index/文件字节；
  见 `evidence-p1.md#p1-t3`。
- P1-T4：`make test:FileTreeTests,GitGraphPaletteTests,DockWorkspaceTests`
  **115/0**，真实 AX/亮暗主题／Graph／Worktree GUI **8/0**；
  6 旗标 × 两种外观 × 两套主题共 256 组像素，
  及 60 个主题变化；见 `evidence-p1.md#p1-t4`。
- P1-T5：`make test:FileTreeTests,DockWorkspaceTests,PanelContextTests,DockFocusIntegrationTests,GitGraphPaletteTests`
  **137/0**，中文／日文合成 marked-text 专项 **1/0**；
  原生 GUI 导航 **1/0**、Palette／rename／Terminal／编辑器／亮色 **5/0**、
  中文命令面板／双原生窗口 **2/0**；所有 Git/文件真实副作用及
  独立窗口字节已断言；见 `evidence-p1.md#p1-t5`。
- `make build:dev`、正式 `make build`、Apple Development 签名及
  `codesign --verify --deep --strict`、`git diff HEAD --check` 全部通过。
  `/Applications/Bailey.app` 已经同卷整包替换并复验二进制字节一致，
  原 PID 24069 未退出/重启，旧包备份清理完成；
  P1 实际运行日志在 `evidence-p1.md` 按任务记录。
  不把失败的第一次 GUI 夹具或错误的 PageDown 断言作为产品修复证据。
- 核对生产链：Selection／Anchor 不等于焦点、Context Target 不打开文件、
  Show／Expanded 根范围隔离、紧凑段携带真实路径、AX Selected 只表达
  Selection、原生 firstResponder 不被不可见树/旧宿主复写。
  `docs/{architecture,ui,testing,development}.md` 的既有职责不改变；
  Files／Git 局部文档与本阶段实际代码一致，无多余双轨兼容入口。

### 环境与极端条件核销

- **已执行**：Apple Silicon／macOS 27.2／Xcode 27.2，Development 签名，
  英文／简中真实 App，亮／暗与多主题，三档字号×两档视口，
  0/1/80/1000+ 行、Unicode／深目录／过滤／压缩／长横向滚动，
  Shift／⌘／多选／边界钳制，菜单取消／改名／新建／Palette／编辑器／
  Terminal／Git／两窗口，异常晚到／断线／同根替换，
  真实本机与授权 Windows SSH 文件副作用。
- **未实测：macOS 15.6**（没有对应真机／VM）：
  原生键盘、SwiftUI 滚动与 AX 仍存在旧系统兼容风险；
  当前 SDK 编译不可取代最低系统验证。
  补验：15.6 真机执行 P1 文件树宿主和导航／焦点/AX GUI。
- **未实测：实体触控板中键、VoiceOver 真人朗读**（当前未提供硬件／辅助功能人工环境）：
  可能存在手势／朗读呈现差异；原生事件、XCUI AX、像素替代测试已通过。
  补验：实体设备逐项手动验收，记录焦点/Selection/Context 的实际声音与视觉。
- **未实测：实际中文／日文系统输入法组合**（未切换用户系统输入源）：
  真实 IME 面板和复杂候选交互未获得系统级证明；
  AppKit field editor 的中日 marked-text 合成及真实中英界面已通过。
  补验：具备输入源的隔离图形会话下验证组词期间导航不截获、不损坏编辑内容。
- **未实测：Windows 原生软链接创建权限分支**（远端拒绝创建）：
  本机链接、硬链接与远端普通文件通过，不声称全部远端符号链接情况通过。
  补验：具备相应权限的隔离 Windows 账号下重跑既有 SSH LiveTests。
- **未实测：Windows SSH 真实断网与两窗口 GUI 的合成组合**
  （单项连接隔离／宿主、双本机窗口 GUI 均已测；未破坏用户 SSH master）：
  在跨窗连线切换时可能存在额外时序风险。
  补验：隔离 SSH master 与专属 Windows 沙盒中同时运行真实双窗断线恢复。
- **测试基础设施记录**：一轮 GUI 调试发生独立项目启动未显示，
  其他启动与正式同项回归成功。现无可重复复现的产品问题；
  若持续出现应独立定位启动器/桌面焦点，不归咎于键盘分页逻辑。
- **Gate 影响**：以上客观环境缺口保留，不能宣称全设备／最低系统完成；
  在当前可安全执行的所有已识别条件下无失败，不构成当前 P1 实现阻塞。

## Gate（是否允许进入下一阶段）

- 结论：**Go（仅对已验证的当前运行环境；不是全平台验收）**
- 理由：P1 五项真实代码及现行文档已原子提交，目标根因和外部副作用已复验，
  本机可执行的宿主／GUI／远端条件通过；未具备的物理／旧系统条件逐项保留。

## 最终状态与剩余风险

- 当前状态：**Resolved**
- 剩余风险：macOS 15.6、真实中日系统 IME、实体触控板／VoiceOver、
  Windows 原生软链接及 SSH 断网×双窗联合 GUI 的环境实测待补，
  不把这些替代证据写成完整通过。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

