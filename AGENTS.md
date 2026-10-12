# Kero 开发规则

这是 AI agent 的开发入口。用户说明见 [README](README.md)，功能维护约束按下表选读。

## 动手前

- 先读受影响功能的维护约束，再追踪入口、状态所有者和最终副作用。定位代码优先 `rtk codegraph sync` 与 `explore` / `node`；索引不足时用源码和测试补证。
- 复用现有实现，修复共享根因。不为单一实现新增协议，不因文件大而拆文件；保持单个 Xcode App Target，不为未来预建包、容器、事件总线或通用框架。
- 在授权范围内完成实现、验证和收尾。发布、推送、破坏性操作或替换用户正在使用的资源，先确认授权；不得中断用户运行中的命令或丢弃未保存内容。

## 不可破坏的边界

- **状态随生命周期归属**：窗口由 `TerminalManager` 协调，项目由 `Project` 持有，标签内部窗格由 `PaneTab` 持有。临时 View 重建不能结束终端、丢失编辑或中断转发。
- **两层布局各有真源**：`DockNode` 管外层停靠，`PaneNode` 管标签内部分屏。移动、关闭和恢复必须保留内容与焦点，不另造并行布局状态。
- **文件与 Git 共用树**：复用 `TreeDisplayModel` 和树行，保留目录压缩、状态、命中范围、悬停、滚动、键盘、无障碍及懒加载。
- **异步结果不能串目标**：发布前核对发起时的项目、机器、连接与请求代次；旧结果不能覆盖新状态。保存失败保留编辑，远程失败不得回退写入本机。
- **沿用平台与后端边界**：SwiftUI 负责界面，AppKit/Ghostty 负责原生终端与输入。复用现有后端契约，保留 Git 刷新合并、SSH 批量执行和超时；布局配置由窗口协调者传入项目，不在项目中读取全局布局设置。
- **生成资源不手改**：图标查询表与资源只经生成脚本更新；第三方源码、补丁和许可按[依赖约束](docs/DEPENDENCIES.md)维护。

## 构建

需要 macOS 15.6+、Xcode 和可用的 Apple Development 证书。工程默认团队为 `RDQHYSDFFG`；使用其他团队时调整签名设置。以下命令从仓库根目录执行：

```sh
bash scripts/prepare-ghostty.sh
xcodebuild -project kero.xcodeproj -scheme kero-dev -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackageUpdates build
codesign --verify --deep --strict "build/DerivedData/Build/Products/Debug/Kero Dev.app"
```

Debug 产物是 `Kero Dev.app`，标识为 `chiimagnus.kero.dev`。正式版使用 `-scheme kero -configuration Release`，产物为 `build/DerivedData/Build/Products/Release/Kero.app`，标识为 `chiimagnus.kero`。两者共享单个 Target 和 `kero` 可执行文件，但不共享设置、快照、历史及隧道。GhosttyKit 缺失时才下载，校验后复用。需要切换 Xcode 时设置 `DEVELOPER_DIR`；没有自动更新。

## 验证

按改动选择[现有检查](scripts/check.sh)，可一次运行多个名称：

```sh
bash scripts/check.sh dock-workspace session-snapshot
```

| 改动范围 | 维护约束 | 检查名称 |
| --- | --- | --- |
| 应用身份与数据目录 | [设置与恢复](docs/SETTINGS.md) | `app-identity settings session-snapshot` |
| 停靠、分屏、焦点与内容生命周期 | [终端与窗格](docs/TERMINAL.md) | `dock-workspace pane-retention` |
| 配置与快照格式 | [设置与恢复](docs/SETTINGS.md) | `settings session-snapshot` |
| 文件树、编辑、读取与保存 | [文件与编辑器](docs/EDITOR.md) | `file-tree-navigation tree-row-hit-testing workspace-identity` |
| Git 执行、操作、草稿与 diff | [Git 与差异](docs/GIT.md) | `git-execution git-panel-state workspace-identity` |
| SSH 连接、转发与面板异步目标 | [项目与 SSH](docs/PROJECTS.md) | `remote-commands remote-lifetime panel-targets workspace-identity` |
| 浏览器导航与重挂载 | [浏览器与开发服务](docs/BROWSER.md) | `pane-retention` |

其他改动按需读[产品原则](docs/PRODUCT.md)、[性能](docs/PERFORMANCE.md)、[本地化](docs/LOCALIZATION.md)、[依赖](docs/DEPENDENCIES.md)与[安全](docs/SECURITY.md)约束。

`workspace-identity` 和 `pane-retention` 须先构建 Debug 开发版；原生视图检查需要 macOS 图形会话。检查使用临时数据或受控后端，不连接真实 SSH 主机，不能代替真实远端传输或用户交互验收。

行为或逻辑改动还须构建、校验签名，并在真机实际操作受影响行为。检查主路径与共享根因的关键边界；性能改动按[测量约束](docs/PERFORMANCE.md)记录前后数据。纯文案改动（名称、标签、翻译等）只核对引用、双语文案、占位符与表名；涉及源码或字符串提取时按需构建，不要求真机操作验收、重装或重签测试包。快捷键、启用条件、动作路由与布局变化不属于纯文案。仅改文档时核对事实、命令与链接，不机械重装 App。

### 真机验收与应用替换

- 正式应用默认位于 `/Applications/Kero.app`。获准替换后，默认只更新磁盘上的应用包；不操作当前实例、终端或编辑内容。退出和重启由用户手动完成；“替换”不包含代为退出、启动或重启的授权。
- 先构建并校验签名，在临时路径准备完整新包；保留旧包备份，再替换目标并校验安装包签名。不得向运行中的旧包逐文件覆盖。复制或签名校验失败时恢复旧包路径；无法恢复则保留备份并说明阻塞，不强退应用或改写用户数据。
- 交付时分别说明应用包是否已替换、重启与恢复是否已验收，以及备份位置。用户重启后检查原有项目、标签与布局；未经确认不宣称恢复通过，也不删除安装备份。仅在用户明确授权代操作时，确认命令和编辑可安全结束，再正常退出或重启。
- 行为验收默认使用同一签名 Debug 包的隔离实例，不为验收重启正式实例：
  ```sh
  open -n -a "$PWD/build/DerivedData/Build/Products/Debug/Kero Dev.app" --args --isolated-ui-test
  ```
  隔离模式单独保存窗口和终端历史，不启动已保存隧道；全局设置仍可能共用，不在隔离实例中修改设置。
- 指定独立测试包时，只更新该包，默认直接使用已签名的 Kero Dev 开发版和隔离参数。不得仅修改 Info.plist 后冒称数据隔离成立；应用数据路径由实际 Bundle ID 决定，检查须覆盖配置与历史目录。
- 真实 SSH 检查只用获准的专用测试 master，不借用用户连接。`bash scripts/check-workspace-identity.sh user host port control-socket` 会在两台机器创建并清理唯一临时目录；缺少条件时明确记录远端未测。
- 验收后只清理本轮创建且可确认归属的临时应用与独立测试数据，保留用户原有数据。编译成功、事件发出或骨架出现不算行为通过；隔离包通过不等于正式包已安装。

## 文档与提交

- `README.md` 面向用户，写用途、操作、结果和必要限制；`AGENTS.md` 是唯一开发流程入口；`docs/` 面向 AI 开发者，只保留维护功能所需的约束、原因与验证要求。
- 功能变化同步更新对应维护文档；用户可见行为变化再更新 README。自有正文使用中文，一件事只详细写一次，不复述源码目录、实施历史或未来计划。`.github/features/` 中的计划不是当前功能事实。
- 独立逻辑改动验证后原子提交，只包含本任务变更。中文标题概括结果，正文写清改了什么、为什么这样改及实际验证；未测部分单独说明。不创建新分支，不擅自推送；明确要求不提交时保持未提交。
- 提交前运行 `rtk git diff --check`，确认没有无关改动或临时产物。
