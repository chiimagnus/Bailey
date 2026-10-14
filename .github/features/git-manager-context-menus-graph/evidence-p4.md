# P4 执行证据

实时状态只由 `todo.toml` 维护。此页区分模型、原生界面与真实机器结果，不把构建或回调等同于 E2E；不沿用旧审计结论。

## P4-T1

- Red：`make test ONLY_TESTING=KeroTests/GitStatusModelTests/testContextChangeDuringMutationPreflightDoesNotSwitchOldRepository`；异步 Git 预检期间切换机器，旧库分支实际变成 `other` 而不是保持 `main`。完整原始日志：`~/Library/Application Support/rtk/tee/1791970983_make_tes_4258da.log`。
- 修复：唯一 `perform` 在准备保存后、异步预检后及每一步副作用前核对既有 generation 与发起目标；Squash 的 staged 检查及条件 Commit 不退出互斥。实际失败 argv、stderr 留在 Operation，不要求 View 解析 transcript。
- `GitCommitActionTests` 6/6：真实临时库证明 Checkout/Root Revert、Cherry-pick -x/NoCommit、Merge 主线、NoFF/FF/Squash/NoCommit、无差异不提交及冲突后 Git abort/continue。不是 PTY 或完整 App E2E。
- `GitCommitDialogTests` 2/2：真实 NSAlert 的字段默认值、父提交选项；Cancel 无副作用、另一窗口 key 不接管 sheet、两个 Project 指向同库时切 Project 拒绝、主按钮实际检出所选 SHA。测试通过 GitPanel 原生呈现入口，不冒称已从右键自动化走完。
- 保存保护直接等待既有 FileTab/DiffTab 写队列，不调用会删 Tab 的关闭 helper；失败、保存期间新编辑与 preflight 期间新编辑回归核对缓冲/HEAD。干净编辑模式 Diff 的原生表面直接重载，不重建、不覆盖 dirty。
- 首轮完整测试 129/129。收尾发现 reset 设置测试会调用共享语言偏好写入；改为可注入的语言 UserDefaults/domain，并只在独立 domain 验证 reset，不把测试隔离错误保留成产品开关。最终完整测试与构建/安装记录待实际完成后追加。
- 清理：全局 key/mainWindow 猜窗口路径、旧 Copy Commit Message 标签已删除；仍被 T3/T5 使用的名称 helper 与轻量 Tag 路径不提前破坏。
- 最终完整 `make test` 130/130；关闭发起窗口及 Always Accept 勾选后实际略过 sheet 的补充 NativeUI 2/2。`make build` 与严格签名 PASS，整包更新 `/Applications/Kero.app`，不启动或重启现有进程；临时原包备份已清理。实现提交 `a5f1c91`，规划文件不入提交，原有暂存 plan 保持原样。

## SSH 条件

- 用户授权已有 `windows` 主机。以 `ControlMaster=no`、`ControlPath=none`、BatchMode 与严格 host-key 验证只读探测；未借用已有 master。
- 实机回答：`MSYS_NT-10.0-19045`，`/c/Users/Administrator`，`/usr/bin/git`，Git 2.56.0。此探测不是 P4 SSH 操作验收；后续只创建测试临时库和独立连接。

## P4-T2（本轮验收）

- 拓扑 Red→Green：Root、Merge、子分叉、当前 HEAD/未知 HEAD、HEAD 后的单子/合并路径；规则不读取 Ref 数量，不额外禁止 Tag 或同节点 Ref。首次 Drop 副作用前另读真实可达拓扑，不能用分页缺节点证明安全。
- 隔离 Git 测试已覆盖 Reset 三层及 Hard 删除 untracked 阻挡、后台 Rebase、Drop 与 detached HEAD。更新引用测试最初错误地期望被排除的 upstream（被删除节点）上的 Branch 也会移到父节点；真实 Git 不这样做。修正为检查实际被重放的中间 Commit 的 Branch，并保留 Tag/remote Ref 验证，未为错误断言改变实现。
- 源码续追确认普通 SSH 带 command 不握手。首个显式环境项路线虽然握手，但复杂 remote command 在 Windows 上真实 parse error，编辑器从未就绪；错误退出还会自动关掉标签，不能查看结果。已停止并删除该路线，不保留兼容或兜底；未修改 Windows wrapper、sshd 或用户配置。
- 当前路线：原 helper 普通登录，新连接拥有独立 socket，Ghostty `input` 一次发送已转义的目标 cwd/命令；现有 SDK `withCustom` 和 1.3.2 引擎实际支持该原生能力。本机 PTY 测试真实等待序列编辑器输入并改写 HEAD，终端保留。Windows NativeUI/真实 SSH 测试在固定主机与自动项目两路均通过（57.244 秒），核对实际 cwd、TTY、HEAD/两分支文件、不同控制 socket 和无本机 backend。自动项目的起始连接元数据是测试拥有的连接，不冒称完整 App 手动 SSH E2E。
- Windows 验证入口：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test ONLY_TESTING=KeroTests/GitInteractiveRebaseTests/testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`。原始日志 `~/Library/Application Support/rtk/tee/1791977590_make_tes_2986c0.log`。远端测试仓库和本测试 source master 在用例成功/失败路径都清理，用户 master 未使用。
- 第二个 Red：把 Project 的 Git 根重新查询作为预检，误拒绝了本机原生检出（日志 `1791975634_make_tes_751a89.log`）。删除这条额外查询；在唯一 GitStatusModel 记录已解析的 PanelContext 身份，新目标解析立即失效旧 generation，未解析快照不允许动作。原生回归恢复 Green；补充切不同仓库及切走再切回不会恢复旧确认，属于 T1 目标绑定的补充修复。
- Windows 额外只读探测：Shell 为 `/usr/local/bin/openssh-zsh-v3.exe`，可调用 `/usr/bin/zsh -ic`。单次空 Git 探测库 `/tmp/kero-p4-Qulkrt`（远端）的单/双引号 Git root 查询均回答相同实际根，不把过去版本的 quoting 假设写成当前缺陷；该临时库已按确切路径清理。只读查看了现有 wrapper 源码，未改服务器。
- 接手后复验（2026-10-14）：完整 `make test` **140 项、0 失败、1 跳过**（未指定专用 SSH 测试主机），日志 `/tmp/kero-handoff-p4t2-test.log`；`make build`、Debug 严格验签通过，日志 `/tmp/kero-handoff-p4t2-build.log`。
- 真实 Windows SSH 专用测试第一次复跑在 pinned=true 完成后、**pinned=false 的 Git fixture 准备阶段**超时，随后使用同一测试 backend 清理也超时。失败日志 `/tmp/kero-handoff-p4t2-ssh.log`；故不能声称自动项目实际 Rebase 失败。使用不借用用户 SSH master 的新连接确认主机正常，再用隔离短期 ControlPath 连续 4 次验证连接复用正常；仅删除该次测试遗留的远端临时目录 `/tmp/kero-p4-ssh-scntw3`（事先确认目录归属、无进程及没有符号链接），未改用户 SSH 配置。
- 第二次真实 Windows SSH 测试 **通过（44.278 秒）**，涵盖 pinned 与 automatic 两种项目、新独立控制 socket、真实目标目录、交互式编辑器等待及最终 HEAD/文件核对。日志 `/tmp/kero-handoff-p4t2-ssh-repeat.log`。首次一次性超时原因暂未证实为产品缺陷，保留该事实；不以盲目重试遮盖。
