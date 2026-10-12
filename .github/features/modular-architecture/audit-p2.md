# Audit P2 - modular-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/modular-architecture/`
- 粒度：`phase`

## 任务看板

- [x] P2-T1 抽离 Files 面板与唯一共享标题
- [x] P2-T2 抽离 Git 面板和破坏性操作确认 UI
- [x] P2-T3 抽离 Info 面板及其数据模型
- [x] P2-T4 让 SSH 转发记录跟随连接，而非工具 View
- [x] P2-T5 收敛同一项目内异步范围校验

## 任务到文件的映射

- P2-T1
  - `kero/Files/FileTreePanel.swift`、`kero/UI/Panels/PanelHeader.swift`、`kero/UI/Panels/PanelSectionHeader.swift`、`ToolPanelView.swift`；18e3fb2、e327401。
- P2-T2
  - `kero/Git/GitPanel.swift`、`GitStatusModel.swift`、`scripts/check-git-panel-state.swift`；c110092。
- P2-T3
  - `kero/Info/InfoPanel.swift`、`SessionInfoModel.swift`、`RemotePaneHeaderView.swift`；97fd6eb。
- P2-T4
  - `RemoteConnection.swift`、`PortForwardController.swift`、`RemoteCommands.swift`、`InfoPanel.swift`、`ToolPanelView.swift`、`TunnelDefinition.swift`、两项 remote checks；34dc7b4。
- P2-T5
  - `Workspace/Project.swift`、`PanelContext.swift`、`Info/SessionInfoModel.swift`、`InfoPanel.swift`、`UI/ContentView.swift`、`CommandPaletteView.swift`、`Panels/ToolPanelView.swift`、`Files/FileTreePanel.swift`、`scripts/check-panel-targets.swift`；2e06a23。

## 发现项

## 发现 F-03

- 任务：`P2-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/RemoteConnection.swift:309`
- 摘要：`最终审计补验复现了master检查后退出的新连接回退`
- 风险：`只复用现有SSH会话的边界在检查/执行间隙不成立`
- 预期修复：`同一连接控制参数禁止新master/新传输，不在File/Git调用方叠守卫`
- 验证：`真实OpenSSH mux/TCP失败前后对照、既有SSH读写及HTTP404并发转发、签名Debug`
- 解决证据：`018d67a；同P5 F-01根因修复，未增加调用点守卫。/tmp/kero-mux-before.log复现检查后新TCP，/tmp/kero-mux-after.log证明无新TCP；/tmp/kero-p5-real-ssh.log与/tmp/kero-p5-real-forward.log证明既有master读写/转发仍有效；最新签名Debug与12项回归PASS。`


## 发现 F-02

- 任务：`P2-T2`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`docs/GIT.md:38`
- 摘要：`使用指南未说明新的草稿寿命与命令面板本机文件边界`
- 风险：`用户可能误以为草稿跨重启保存，或以为SSH文件搜索仍会读取远端`
- 预期修复：`说明窗口内仓库草稿规则及文件搜索只支持本机；不写未验证增强`
- 验证：`对照模型与命令面板实际条件及链接`
- 解决证据：`Git/Terminal指南与模型/命令面板条件一致；diff --check PASS；同一修复提交。`


## 发现 F-01

- 任务：`P2-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Files/FileTreePanel.swift:191`
- 摘要：`Files旧菜单的Rename与新建草稿入口未使用已建立的目标校验`
- 风险：`同一Project在菜单存续期间跟随终端切到另一目标，旧action可在已重定向的FileTreeModel上启动编辑；rename的scope捕获发生在action之后，不能保护这一步`
- 预期修复：`复用原目标谓词核对新建/rename入口与Task实际发起点；不增加generation或操作管理者`
- 验证：`延迟backend回归、真实文件树rename/create、签名Debug build与源码入口核对`
- 解决证据：`新增入口复用isCurrentTarget；延迟backend和真实文件树创建/rename回归、签名Debug build PASS；提交见git最新FileTreePanel变更。`


## 修复日志

- F-01/F-02：3799427，补齐旧菜单编辑入口校验与人类使用说明；未增加状态代次、管理者或生产测试注入。
- P2 各迁移只保留唯一实现。Files 的 Project 持有者、Git 的窗口持有者、Info 的 View 刷新入口没有另建镜像；SSH controller 的连接所有权与 backend 的请求所有权实测可释放。
- F-03：最终审计发现并复现 master 存活检查后消失时 OpenSSH 新传输回退；018d67a 在共享控制参数禁止新 master/新传输。真实 mux/TCP 反例修复前失败、修复后通过；实际既有 SSH 的 File/Diff/Git 和并发 HTTP 转发仍通过，见 `audit-p5.md`。

## 验证日志

- `check-panel-targets`（编译真实 PanelContext/Info/Files 与延迟 WorkspaceBackend）-> PASS。旧根晚返回、foreground/机器/连接/状态身份、同 PID 换目标、旧菜单动作在新表仍含该 PID 后拒绝、最后目标刷新与 cwd 无关的进程目标、延迟创建不打开到新项目、确认后目标变化不发送删除。
- `check-git-panel-state` -> PASS。真实临时仓库 stage/unstage/discard、失败保留、提交期间编辑保留、成功匹配清空、不同scope同路径/同仓子目录/提交期间切目标；最终文件/索引/log 有断言。
- `check-file-tree-navigation` -> PASS，真实 create/rename、root/scope展开隔离、symlink与不可读边界、10k文件约0.108秒。
- `check-tree-row-hit-testing`、`check-dock-workspace` -> PASS，原生两档字体点击/附件隔离、Dock树/顺序/存档。
- `check-remote-commands`、`check-remote-lifetime` -> PASS，无网络命令解析/占用与真实connection/controller/backend引用释放。真实独立 Test SSH master 的两次并发转发复用18080；HTTP404证实远端临时Python服务可达；正常退出交互SSH后监听与socket均不存在。
- Debug `xcodebuild`、`codesign --verify --deep --strict` -> PASS。最终源码原生日志 `1791755869_xcodebui_eb0633.log`，见 `/tmp/kero-p2-audit-build.log` 的 tee 路径。
- Kero Test/sh.kero.test 实机：Files创建/打开/rename与标签更新；最新审计包 `audit-renamed.txt` 存在、旧名不存在；Git工作/历史树及切换Files/Info后的草稿；本机Info显示自己的Python PID/18081端口，Copy URL最终剪贴板正确，终止后PID与监听消失；未操作正式 Kero。
- 命令面板本机搜索并打开fixture文件；坏`.gitmodules`使递归`ls-files`实际返回128，普通fallback返回0，UI仍显示并可打开文件；同路径Windows SSH目标搜索同名文件，结果没有本机文件行。远端临时空目录正常rmdir，SSH正常退出。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P2职责归属与确定性生命周期/目标校验完成，三项审计发现均已修复；模型、真实副作用、签名包关键路径与源码映射一致。最终补验的构建、12项回归及真实SSH也通过。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：可安全访问的真实SSH是Windows/MSYS，现行Info进程/端口命令要求Linux；远端Info端口行、复制URL/移组后的记录可见性未端到端实测，不把Windows空行当Linux通过。controller合并、真实forward/HTTP/监听寿命已有证据；UI使用ObservedObject直接观察原表，无复制状态。Files确认/延迟打开的回归覆盖目标值及真实模型，NSAlert内切换机器的时序未实机制造。全面无bug不是可证明结论。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

