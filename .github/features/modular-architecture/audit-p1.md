# Audit P1 - modular-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/modular-architecture/`
- 粒度：`phase`

## 任务看板

- [x] P1-T1 核对代码所有权与基础回归
- [x] P1-T2 共享树唯一归属与旧路径同步移除
- [x] P1-T3 文件树模型归入 Files，项目持有者不变

## 任务到文件的映射

- P1-T1
  - `kero/App/keroApp.swift`、`kero/UI/ContentView.swift`、`kero/Workspace/Project.swift`、`kero/Terminal/TerminalManager.swift`
- P1-T2
  - `kero/Shared/Tree/TreeDisplayModel.swift`、`kero/Shared/Tree/TreeRowStyle.swift`、`docs/CONTRIBUTING.md`、`scripts/check-file-tree-navigation.swift`
- P1-T3
  - `kero/Files/FileTreeModel.swift`、`docs/CONTRIBUTING.md`、`scripts/check-file-tree-navigation.swift`

## 发现项

未发现本阶段引入的实现缺陷。三份迁移源码与迁移前版本逐字一致，调用方无需兼容转发，Xcode 同步目录自动接入。

## 修复日志

- 无需额外修复；原子提交为 `26a3f4e`、`01c3c1c`，计划文件未混入提交。

## 验证日志

- `check-dock-workspace` 原命令编译/运行 -> PASS。
- `check-file-tree-navigation` 以新 Shared/Tree、Files 路径编译/运行 -> PASS；实际创建/重命名、不同根和机器展开隔离、不可读根、symlink 上限、10k文件（0.110秒）。
- `check-tree-row-hit-testing` 以新 Shared/Tree 路径编译/运行 -> PASS；真实鼠标命中缩进、上下/尾部边缘与附件隔离，两档字体。
- `xcodebuild` 文档 Debug 命令 -> BUILD SUCCEEDED；`codesign --verify --deep --strict` -> PASS。原生输出证据：rtk tee 的 `1791753504_xcodebui_eb0633.log`、`1791753644_xcodebui_eb0633.log`。
- 经用户授权正常退出并安装/重开正式 Kero，观察四个项目与标签恢复，Files/Git 工作区、暂存及历史压缩目录和无障碍标签，展开历史显示真实变更文件。
- 用户随后要求不占用正式 Kero，后续验证改用已重新签名的 `build/Kero Test.app`（sh.kero.test，--isolated-ui-test），实际添加临时仓库、压缩/展开目录、打开长名称文件。隔离模式仍共享字体/外观，不修改用户设置。全局 PRODUCT_NAME 覆盖会影响 SwiftPM 所有依赖而发生产物重名，未采用；测试包复制成功的 Debug 并仅修改应用标识/显示名后重签，未改产品源码或依赖。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：职责迁移与旧路径清除完成；逐字源码对照、受影响共享原生回归及签名包实际树操作共同支持无逻辑回归。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：未做 SSH 端到端，未逐项实测 hover/横向滚动视觉；相关行组件源码不变，字体与点击边界有原生回归。用户新要求覆盖后续正式替换操作；P5 只在用户届时授权后替换，不因先前授权继续占用正式应用。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-12 执行完成后的独立复审

本轮不读取旧 audit 的发现、结论或验证记录，以当前 plan/todo、逐提交 diff、实际消费者和重新运行结果判断。

- P1-T1：`bfe8602` 仅计划变更，对产品目录无差异；重新确认 WindowRootView 持有窗口 manager、ContentView 持有 Git、Project 持有 fileTree/Dock/tabs。
- P1-T2：`26a3f4e` 两个源码 rename 均 100% 相同，旧路径删除；导航脚本和文档编译路径同步。Files 与 Git 工作/暂存/历史实际引用同一 TreeDisplayModel、TreeFolderRow、TreeFileRow，未新增树框架。
- P1-T3：`01c3c1c` FileTreeModel rename 100% 相同，实例仍由 Project 创建，所有实际面板消费该对象，旧路径删除。
- `53d747c`、`72ee408` 仅计划/执行状态文件，不计为功能实现；未使用其中旧 audit 的结论作为证据。
- 独立重编译 Dock、真实文件树导航（10k 约 0.108 秒）、两档字体原生行命中均 PASS，日志 `/tmp/kero-independent-p1.log`。本轮最终签名 Debug 构建和严格校验也通过。
- 本轮 Gate：Go；没有新发现。没有机械删除共有树的命中/路径安全边界，没有把搜索零结果当端到端通过。

