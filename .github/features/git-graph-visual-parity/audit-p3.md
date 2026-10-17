# Audit P3 - git-graph-visual-parity

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/git-graph-visual-parity/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 对齐提交行布局密度与Merge状态
- [x] P3-T2 节点悬停与跨场景视觉回归验收

## 任务到文件的映射

- P3-T1 — `48506e9c937fb8ba7b4bcfc3247e09a069c3e1a8`
  - `kero/Git/RecentCommitsView.swift`：唯一提交行 `commitRow` 调整为「Ref/Stash → 标题」，Merge 只弱化标题，SHA/作者/相对时间不改变原生交互。
  - `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：按实际布局更新标签、标题、Tag、右键命中；未修改共享树组件。
  - `docs/features/git.md`、`docs/ui.md`：同步图谱显示与行内动作说明。
- P3-T2 — `d12e93718264ac5975bc2c1b2de12d5e6610b21e`
  - `kero/Git/CommitGraphLayout.swift`：基于加载的父边一次计算 `knownHeadHistory`，只证明可达，不推断未加载历史。
  - `kero/Git/RecentCommitsView.swift`：原生节点 `help`、局部圆形命中及完整 SHA／直接 Ref／Stash 提示；与既有 `toggle` 和提交菜单同一消费者。
  - `KeroTests/Unit/Git/CommitGraphLayoutTests.swift`：Detached HEAD、Merge 多父、交叉拓扑、缺页、1001 行 31 车道及 30 次计时。
  - `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：本地化悬停内容、原生节点点击只切换一次、右键不串目标。
  - `kero/Resources/Localization/Git.xcstrings`、`docs/features/git.md`、`docs/ui.md`：中文提示与行为合同。

## 发现项

## 发现 F-01

- 任务：`P3-T2`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`.github/features/git-graph-visual-parity/plan-p3.md:67`
- 摘要：`独立 App 菜单、分页及系统悬停气泡没有在同一前台 E2E 流程中完整复测`
- 风险：`已在隔离真实 App 中证实图谱显示与节点展开，但这三项在独立进程中仍属于未验证，不能把 NativeUI 测试冒充完整独立进程 E2E`
- 预期修复：`在不会干扰用户工作会话的专用图形桌面中，使用隔离仓库补做 +N 右键、30→60 翻页与实际帮助气泡的同一路径验收`
- 验证：`在独立 macOS GUI 会话启动 --isolated-ui-test，截图记录菜单各项、翻页前后行数与节点 hover；保留对应 App 及 Git fixture 证据`
- 解决证据：`替代性覆盖：RecentCommitsViewTests 20/20（真实 NSHostingView 菜单、Tag/Ref/Stash 命中与分页触发）、GitStatusModelTests 26/26（真实 Git 30→60 分页）、真实隔离 Kero App 的图谱与 Merge 节点展开 side.txt 已验证；但用户使用的桌面焦点持续改变，未能可靠地在同一独立 App 完成菜单+分页+系统气泡的全过程。无已复现产品功能错误，待专用 GUI 环境补测。`


本阶段发现项由工具记录并追踪。源码、操作权限、节点与数据归属未检出可复现的阻塞级缺陷；F-01 是独立进程的完整 E2E 证据缺口，不等同于已确认的产品 bug。

## 修复日志

- P3-T1 把 Ref 排到消息前后，原有坐标测试准确复现了错误命中；在该任务内根据新的真实元素位置重测，保留 Tag 第二次点击不收起、各个 Ref 右键不串目标、标题展开等原有合同。
- P3-T2 的 Hover 不额外发 Git/SSH 请求或建悬浮窗口、缓存、定时器；复用 `TreeRowSurface`、局部透明节点 Button 和现有 `CommitGraphLayout`。实际 MAC AX 控件定位与右键 XCTest 匹配代码；旧版固定蓝色路径、系统配色与 Capsule 已在所属任务清理。
- F-01 未作虚假修复：因用户正常工作会话使隔离窗口焦点/几何频繁变化，原生 GUI 自动化无法可靠完成一条从右键菜单到翻页的**同进程**录制路径。保留 `Deferred`，给出针对性补测入口；没有为了通过流程往产品加专用自动化接口。

## 验证日志

- `make build` + `codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app` → **PASS**，Debug macOS App 成功签名，无 Swift 编译错误；Xcode CoreSimulator 版本警告不影响 macOS 构建。
- `make test` → **PASS**，全部 397 项、0 失败、6 skipped（全部为需要授权 Windows SSH 主机的 live fixture）。日志：`/tmp/kero-graph-final-all-tests-20261017.log`。
- `make test ONLY_TESTING=KeroTests/CommitGraphLayoutTests` → **PASS**，20/20（P3-T2 新增交叉 DAG 及 30 次性能采样后）；1001 行、31 车道、30 次 Debug 布局：median 0.077s、p95 0.079s、max 0.080s。
- `RecentCommitsViewTests` → **PASS**，完整全量 XCTest 中 20/20，标签独立点击/右键、Stash、中文与标题、节点命中、分页触发、无整体横滚；`GitStatusModelTests` 26/26，`GitRemoteBranchActionTests` 15/15，`GitStashActionTests` 12/12，`TreeRowHitTestingTests` 5/5 均在全量测试中通过。
- **真实独立 macOS App**：以 `--isolated-ui-test` 新启已签名 Debug 实例，打开受控 `/tmp/kero-git-graph-ui-*` 仓库（36+ Git 提交、Merge、Tag、Stash、`origin/HEAD`）。辅助功能树显示 GIT GRAPH 37 项、`main`、`origin/main`、折叠中的 `v1.0, origin/HEAD`、Stash；真实截图为 `/tmp/kero-graph-e2e-git-real.png`。再对实际 Merge 节点执行 `AXPress`（返回 code 0），截图 `/tmp/kero-graph-e2e-ax-node-after.png` 证明正确展开 `side.txt` 历史文件。
- 独立 Debug App 进程、仅供本轮测试的 Git 仓库和快捷链接均清理；正式 `/Applications/Kero.app` 进程 PID 10096 **未被退出或重启**。再次 `make build` → **PASS** 后，用同卷临时目录整包暂存安装、安装前后执行 `codesign --verify --deep --strict`，新包成功更新至 `/Applications/Kero.app`，无残留暂存/备份。当前运行进程仍保持旧代码，用户自行重启后新包生效。上述截图没有写入项目提交。
- `git diff --check`、`todo validate`、六个提交的变更文件列表、最新 `GitPanel → GitStatusModel → RecentCommitsView → CommitGraphLayout` 调用链与参照截图核对 → **PASS**；本轮没有读取既有审计结论来取代源代码检查。
- 当前文档职责：Git 拓扑、Ref 绑定与 Stash 动作 `docs/features/git.md`；仅图谱外观、悬停、行密度 `docs/ui.md`；验证策略引用 `docs/testing.md`。未增加重复实现或全局 Theme 特例。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（保留 F-01 `Deferred` 的已声明验收边界）
- 理由：P3-T1/T2 两项已独立提交并真正接入现有 Git 面板；构建验签、全量 XCTest、强化的图谱/原生交互测试和隔离独立 App 实际历史文件展开均已通过；尚未复测的**单一独立 App 完整菜单→分页→帮助气泡链路**已在发现项中明示，不冒充通过，也未发现现行功能错误。

## 最终状态与剩余风险

- 当前状态：`Resolved`（实现与自动化验证；单独图形桌面最终 E2E 作为 `Deferred` 跟进）
- 剩余风险：F-01 独立进程完整菜单/翻页/气泡联动仍未逐项走通（但每项已有 NativeUI/模型证明）；6 个授权 Windows SSH 条件测试在未配置专用测试主机的这轮全量运行中被正确跳过。未声称 Git Graph 可保证任何输入下无 bug，也未将当前隔离 UI 截图当成与 VS Code 不同 DPI 的逐像素相等证明。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
