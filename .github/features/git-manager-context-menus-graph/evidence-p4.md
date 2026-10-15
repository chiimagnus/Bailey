# P4 执行证据

## P4-T9：全对象菜单、真实 SSH 与审计收口（已完成）

- 最终无人干预全量：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，日志 `/tmp/kero-p4-t9-final-full-green.log` 与 `Test-kero-2026.10.15_13-18-18-+0800.xcresult`，**222/222、0 failures、0 skipped**。`GitInteractiveRebaseTests` 本机与真实 Windows SSH 2/2；`GitWorkspaceSSHTests` 真机工作区、远端归档/文件重置/Stash/Clean/Ignore 1/1；没有人工菜单解阻。
- F-15：上一轮全量 `/tmp/kero-p4-t9-final-222-windows.log` 的唯一失败是本机 PTY 序列编辑器在标记文件出现后、第二次追加 `PTY` 前被测试读取。CodeGraph 逐字追到 `GitInteractiveRebaseTests.swift:76` 的过早存在性判断，`bcd3ced` 将等待条件改为完整目录和 `PTY` 内容，生产终端与 Rebase 执行链未改。含 Windows 的针对性 2/2 `/tmp/kero-p4-t9-rebase-focused.log` 转绿，后续完整 222/222 通过；没有靠固定 sleep、跳过用例或人工按键造绿。
- `make doctor`：Xcode 27.0；`make build` 与 `codesign --verify --deep --strict` 均 PASS，日志 `/tmp/kero-p4-t9-final-build.log`。从验证通过的 Debug 包整包替换 `/Applications/Kero.app`，安装后独立严格验签并确认与构建产物可执行文件 SHA256 相同（`2cf884f3807b88fbdd7ca341e6e4de0b138d8706d92ae31f616f521b37655b26`）；原有正式 PID40825 未退出或重启，用户配置 SHA256 仍为 `a23668bd5e043f0da30cbb02b307c0c5f0a99da7cb8d20c5d4a437adb5e1cf3c`。磁盘新包仅在用户自行重启后进入该现有进程。
- 阶段结论：P4-T1～T9 全完成，审计 F-01～F-15 均已解决。旧全局菜单猜窗口、旧引用创建与 Diff 可选字段、无参盲 Stash Pop 等淘汰入口无现行源码引用；VoiceOver 的真实 AX 可操作性已验收，未启动系统朗读。Issue #2 的 SSH 外部自动刷新仍是另案，不能据 P4 菜单验收关闭 Issue。

- 补充审计修复：F-07 `7b62892`、F-08 `1c05cd7` 后，无外部输入的完整 Windows SSH 回归 **217/217、0 failures、0 skipped**，日志 `/tmp/kero-p4-t9-verified-final.log`；build/严格验签通过并整包安装，正式 PID40825 未重启。此结果在 F-10/F-11 之前，不替代其最终回归。
- 完整 App 的 Branch 重名确认：Choose Another Name 保留名称与 Checkout=false；外部移动420015后确认替换被拒绝并保留新 OID；重新确认成功，另建420019不切 HEAD。Tag420016的 Annotated/中文多行说明/不推送默认值均实际读回；改名再试保留所有输入，替换后对象 `7f61e1f4f128c29b3686d5de3c86fa7773da06ec` 指向 sandbox `cf71a75d0b70adba4b12ccca8fef79a6df0bb4ee`。详情为不可编辑原生文本。Push 默认 backup而非origin，Always Proceed=false，取消不改服务器，Proceed后仅backup出现该Tag。普通配置 SHA256 未变。
- F-10 `fcd80bd`：补齐七个 Git/Sidebar 当前键，JSON、NativeUI4/4、build/严格验签通过；重启的仅是隔离测试 App，真实 Tag 详情已显示中文“提交/关闭”，不是只检查资源文件。
- F-11 **完整 App Red**：Fetch表单打开后外部把本地side移动至44af4cf，旧Force仍覆盖为dd445d6。`53fb771`在打开表单时捕获实际本地目标 OID并沿唯一perform校验，删除原只核对只读tracking目标的路线。原生真实表单回归先Red后Green1/1，包含过期拒绝、新确认Force和正常快进；相邻Remote集成13/13。日志 `/tmp/kero-p4-t9-fetch-red.log`、`/tmp/kero-p4-t9-fetch-green.log`、`/tmp/kero-p4-t9-fetch-adjacent.log`；最终全量和新版完整App复验继续进行。
- `aaf69f6`：原生 `NSHostingView.menu(for:)` 在直显当前/其他Branch、Remote、轻量Tag命中点均只解析对应菜单，不混入Commit菜单、不触发左键动作；`RecentCommitsViewTests`10/10。直接向NSWindow发送right事件没有进入同一路径，失败试验日志保留，不以其假象修改产品；此项是NativeUI菜单解析，不冒称物理鼠标E2E。
- 追加回归前的完整测试 `/tmp/kero-p4-t9-complete-windows.log`：**219/219、0 failures、0 skipped**，400.688秒，无菜单解阻或外部UI操作。执行期间只读审查发现远端“Checkout Existing & Pull”未覆盖F-07名称预检，先记录F-12再加真实回归；该新增测试不在219项结果内。`/tmp/kero-p4-t9-existing-alias-red.log`实际证明：确认字面Ref `-` 后无错误地切到previous且HEAD改变，三条断言失败。
- 新版隔离App PID551：真正右击Remote Badge用foreground/synthOnly得到唯一正确菜单；AXShowMenu对嵌套Badge会先显示父菜单、Escape后露出子菜单，因此不据该工具路径增加产品特判。F-11复验通过：Force确认期间side由dd445d6移动到44af4cf，确认报失败且44af4cf/HEAD不变；新确认Force才更新至dd445d6。Pull No-FF/Squash默认off；第一次真实Git因分叉且fixture未配置pull策略而拒绝，明确显示原始错误，与固定上游相同argv一致。只在专属fixture配置pull.rebase=false后Squash成功，实际新提交b66f7ca只有父cf71a75并含side文件。
- 本机Branch真实菜单：safe Delete遵循Git原生上游合并判定，删除side而保留服务器Ref；无上游且未合并的e2e/drop-template触发二次强删，Cancel保留，确认Force才删除，e2e/drop不受影响。e2e/push三模式逐一执行：Normal和过期tracking的Force With Lease均失败、服务器仍aa25cdb；明确Force后服务器变为选定非HEAD的root88fa217，HEAD b66f7ca不变，并设置正确upstream。
- PID551随后正常结束，原因未证实；发现新PID3361无isolated参数，**没有操作或退出它**。重新启动且只控制自己的PID3581（start identity1792038170622887、window71355），正式PID40825始终不变。普通配置文件SHA256未变。新的隔离进程按当时系统语言显示英文；没有为了验收改用户语言偏好。
- Commit真实菜单→表单：Drop middle Cancel保留，再确认使tail从96d629b重写到be99f0b，父为root，middle文件消失、tail保留、原e2e-middle Tag仍465c24a。Cherry Pick勾选Record Origin+No Commit后HEAD不变且index实际新增side.txt；清理fixture后仅Record Origin产生提交3344936，消息有原SHA脚注。对新提交的Revert产生52de9b8并移除side文件。Reset先Soft取消不变，再分别Soft/Mixed/Hard到root，逐次核对HEAD/index/working：Soft留tail暂存，Mixed留tail未跟踪且index干净，Hard从原索引恢复状态后删除tracked tail但保留普通untracked。
- 交互式Rebase在新原生终端真实启动：默认Interactive=false/Ignore Date=true，选Interactive后TTY编辑器写出实际仓库路径并等待，HEAD仍be99f0b；只向自己窗口已聚焦的Terminal发送Return后完成，HEAD984aa87的父为所选dd445d6，tail/side均存在，新终端保持显示成功结果。没有以操作启动成功代替Git完成。
- Stash真菜单：非顶部stash1 Pop默认不恢复index，成功只移除第二条并恢复src内容；原stash2移位为stash1后Create Branch输入420020，实际checkout其base aa25cdb、恢复tracked暂存内容、成功移除该条。Drop取消不删；确认期间外部新建stash使selector移位，旧确认报错且两条都保留；新确认只删新条目。Pop Latest表单核对固定selector/OID与Reinstate Index=false，Cancel保留。显式--index Pop遇到原有untracked同名冲突，错误后原stash保留，tracked暂存和src恢复的部分结果保留、原untracked内容未覆写；没有自动hard reset产品状态（后续仅CLI清理测试fixture）。
- Tag真实创建Lightweight420021并选择backup，后续Always Proceed默认false，Cancel后本地Tag仍指向cf71a75、两服务器无此Tag。轻量Tag菜单无Details。Delete默认Don't Delete on Any Remote，Cancel保留、新确认仅删本地；另明确选择backup删除420016，服务器及本地均移除，其他原Tag保留。原annotated Tag Archive经NSSavePanel选TAR、文件名e2e-tag.tar；保存期间将当前HEAD切到984aa87，实际TAR仍是Tag aa25cdb，含main/side、不含tail，原始tracked字节base；文件移到fixture父目录避免污染后续Git。
- 历史原文真菜单打开root tracked.txt，实际无增删装饰且显示base。辅助功能定向type走AX值写入，把显示变成99base，而不是物理按键；源Git/disk未改变。已据实际效果记录F-13并追到STTextView未校验isEditable的值setter；只修共用DiffTextView的只读边界，不改第三方源码，也不以模型isEditable=false冒称界面不可写。
- F-13 `8cafd13`：原生Red五条失败→History11/11、相邻DiffTab16/16及build/严格签名通过；新隔离App PID10883实际AX值显示settable=false，set-value明确拒绝，文本始终base。历史原文、历史Diff与Revision↔Worktree均只读，普通Open Working File仍是可编辑FileTab。工作区从working E2E变为working newer后重新选中比较标签，右侧实际更新、历史侧仍base。文件与目录的绝对/相对复制实际读回本repo路径与tracked.txt/src；原生菜单关闭后的异步写入另一次观察确认，不以即时旧剪贴板冒称成功。Reset File本机Cancel保留index=working newer/worktree=reset candidate，确认后两侧base，HEAD984aa87不变，同一普通FileTab重载base。
- 新版Windows完整App：Force Fetch打开后side被外部移动ec23bab→246a4fb，旧确认拒绝且HEAD/side保留246a4fb；新确认Force才改side至ec23bab，HEAD仍246a4fb。切项目后+N菜单重新取快照，未据自动化陈旧AX目标修改产品。Checkout Remote同名side→Choose Another Name保留输入，Cancel不切饿e-main；重新确认Checkout Existing & Pull后真正切到side/ec23bab。随后origin/main的默认Pull（NoFF=false、Squash=false）真正快进side到246a4fb。
- Windows Tag420022从root创建默认Annotated、空注释并选origin；本机远端Git实际Tag对象f89b2c41734b1226e2b635e41d62da3097a996aa及服务器Ref均存在，Mac库无此Tag。真实详情原生不可写且显示root a09d483、创建人、Unsigned；Delete默认不删远端，显式选origin后两端均移除，HEAD不变。
- F-14完整App Red：Windows新建空.gitignore后原生挂载替换初始读任务，Ignore未追加。受控双读取Red六条失败，同时证明已有缓存会被错误使用。`9d5c722`沿同一目标当前拥有的读取代次等待（无新增IO或sleep轮询），FileTab14/14、GitWorkspaceMenu4/4、build/严格签名通过。PID15033关闭自己的空标签，确认该远端文件为空后精确删除，再从真实未跟踪行重走Ignore新建→原生挂载→追加→保存，最终文本和磁盘均为`/literal\[1\].txt\n`，真实`git check-ignore`命中，Mac库没有.gitignore写入。
- 最后本机完整App补验：Commit Merge默认NoFF=true/Squash=false/NoCommit=false，Cancel保持984aa87，确认后实际双父提交2f197a3（父984aa87和44af4cf）并包含main/side/tail。Branch main的Merge勾选No Commit，HEAD保持2f197a3、MERGE_HEAD为40f9a01且.gitignore暂存；原生zsh标签内实际执行`git merge --abort`后结束合并、原HEAD与文件保留，终端可见命令和成功返回提示。
- Commit Checkout默认Always Accept=false，明确确认后真正进入root88fa217的detached HEAD；回到e2e/drop使用其本地Ref Switch。Branch Rebase表单绑定main40f9a01，Interactive=false/IgnoreDate=true；确认当前聚焦sheet和PID后发送全局Escape，另一次观察证明sheet消失且HEAD不变。此前PID定向Escape会错误聚焦主窗、未确认取消，已据实际sheet补做Cancel，**不把先前未验证派发记为键盘通过**；菜单自动化现在先等实际sheet关闭，避免向其背后排队。顶部Create New Branch默认Checkout=true，输入420023后Return实际创建并切到同一HEAD2f197a3，sheet关闭。
- 冲突完整用户闭环：只在专属fixture构造A/B分支，Branch B的Merge真实产生tracked.txt三个index stage，HEAD34005f3不变、MERGE_HEAD95eca1c与冲突标记保留，面板显示失败与MERGE CHANGES。真菜单Open Conflicted File打开普通原生缓冲；键盘选择/粘贴resolved E2E并⌘S后核对真实磁盘；Mark Resolved (Stage)清除unmerged stages并写入真实index；填写消息420024、Commit 1 Staged File后生成双父4ba512d（34005f3、95eca1c）、MERGE_HEAD消失、消息清空，文件内容正确，没有自动清空冲突或伪造完成。
- STAGED真文件菜单Open HEAD File显示不可写的resolved E2E，不是index中的staged preview；同路径同时有staged/unstaged时菜单归属正确。目录src的Stage仅添加src/inside与此前tracked.txt，未处理elsewhere/outside；随后src的Unstage仅移除src，保留tracked暂存和全部工作区修改，最后只用CLI清理专属fixture。当前Branch菜单实际只有Rename/Push/Archive/Copy，不含Switch/Delete/Merge/Rebase。Files/Git共享树的原生命中、长路径/窄栏/缩放/滚动由同目标NativeUI继续回归；VoiceOver基础以真实AX名称、可操作菜单、焦点及只读settable验证，未启用系统朗读服务，不把它写成语音人工验收。
- 第二次全量 `/tmp/kero-p4-t9-final-full.log` 记录 **215/215、0 failures、0 skipped**，但**不能作为无人干预 Gate**：进程99729采样 `/tmp/kero-p4-t9-test-sample.txt` 证明旧 Tag 类型测试停在 `NSContextMenuTrackingSession`，依赖人工菜单输入。只对这个测试 PID 发 Escape 后才继续完成。F-09 已用控件原 action 替换误用的 NSPopUpButton.performClick，并补消息编辑状态断言；无外部输入专项4/4通过，提交 `c555404`。后续最终全量必须不再人工解阻。
- 继续按真实路径审查发现 F-07：`git update-ref refs/heads/-d HEAD` 可创建外部 Ref，旧 `switchBranch` 执行 `git switch -d` 会成功游离 HEAD；名为 `-` 的 Ref 还会触发前次检出简写。真实 Model Red `/tmp/kero-p4-t9-switch-red.log` 同时复现两种错误；共享入口按 Git 原生 `check-ref-format --branch` 校验并结束选项，普通分支仍需回归，不在 View 堆特判。
- F-08 的真实原生重名链 Red `/tmp/kero-p4-t9-ref-red.log`：Branch/Tag 两者在确认打开后被外部移动且状态快照刷新，旧 Bool replacement API 会重新取新 OID 而继续强制替换。新用例还走初始缓存没有 Ref、Git 报 already exists 后的二次确认、Choose Another Name/Cancel 保留输入以及重新确认后的成功副作用；修复应固定打开确认时的实际 OID，而非回调时刷新授权。
- 用户要求原有 staged 内容也提交：原回归测试 `320b4cc`，原暂存的 T7/T8 记录与状态 `c0edf54`。后续新建 audit 和新增计划修改仍按 Skill 默认留本地，不把未完成 T9 冒称完成。
- 独立 Debug App：PID75571，process start identity `1792006675711064`，run ID `83D2ACAF-CC65-44E2-A10E-C719AFFFA134`，主窗口69830；正式 `/Applications/Kero.app` PID40825 不启动/不退出。配置 SHA256 仍为 `a23668bd5e043f0da30cbb02b307c0c5f0a99da7cb8d20c5d4a437adb5e1cf3c`。Peekaboo 使用 `--no-remote`，不启动 daemon/Bridge，不操作浏览器；原生 sheet 代理窗的工具拒绝与未验证派发不算功能通过，均以重新观察和 Git 结果判断。
- 本机临时库 `/tmp/kero-p4-ui.sN0hKI/workspace`：实际 Add Files 原生选取后，CHANGES/STAGED 标题右键均出现 Stash/Reset/Clean。Stash 默认空消息、含 untracked，Cancel 保留两个旧 stash 和所有文件；确认消息 `E2E local stash` 后 stash0 新增，index/worktree 干净。对非栈顶 stash2 Apply 并选 index，实际恢复 `stash first` 的 worktree/index而不删除 stash。Reset Mixed 默认保留 worktree且清 index；明确 Hard 后 tracked 回到 base，HEAD 不变。
- 本机特殊文件 `literal[1]*.txt` 从实际行菜单 Ignore，新建普通 `.gitignore` FileTab 保存 `/literal\\[1\\]\\*.txt`，`git check-ignore` 成功且规则不扩散。将规则提交进专属 fixture后，Clean Cancel 无副作用；关闭 Directories 仅删 plain.txt，保留 untracked-dir/file.txt 与被忽略文件；默认开启后目录删除，忽略项保留。原生树行回归通过后继续加强为菜单真正挂在 LazyVStack 内部的行上，而非滚动容器上的测试；没有据工具派发失败修改共享产品行。
- 专用 Windows UI fixture `/tmp/kero-p4-ui-remote-7uQn4y/workspace`，探测 master `/tmp/kp4-ui-AF5B7F61.sock`，App backend socket 按其 PID 独立。通过 Add SSH 原生表单实际接入；STAGED 右键 Stash，消息实际读回 `E2ESSHstash`，远端 stash list 三条且 index/worktree 干净。Merge Commit 菜单齐全，Drop 禁用；Cherry Pick 表单两个 Parent、默认第一父、Record Origin/No Commit 均 off，Cancel 不写入。
- Windows 当前 Branch 从真实右键 Rename 变为 `饿e-main`（系统中文输入法提交的实际名称，不伪称 ASCII 输入）；Push 表单 Set Upstream=true、Normal、origin 默认选中、backup 未选，确认后服务器确有完整 `refs/heads/饿e-main`。+N 的同名 remote 子菜单与直显一致，无 Fetch-to-current；Delete 确认后服务器该 Ref 消失，其他 main/side 保留。
- Windows 非当前 branch-old 的 Archive 经原生保存面板选 ZIP，实际本机文件是 fixture 内的 `:tmp:kero-p4-ui.sN0hKI:ssh-ui-root.zip`（保存名称中的 `/` 被系统当作名字字符转换，记录实际路径，不冒称导航到另一目录）。`unzip -l` 验证根提交 `a09d48339bbb6034b9eed0ecfb45dfd4e816688c` 内容，没有 HEAD 后增的 main.txt/side.txt；不是当前 HEAD 归档。
- Windows 历史 tracked.txt 真菜单 Reset File：先构造 index=`remote overwritten candidate`、worktree=`remote worktree candidate`；Cancel 后两者原样。再次打开确认后，远端 worktree 还原 `remote base\r\n`、index 为 `remote base\n`，符合该 fixture 的 autocrlf；HEAD/当前 Branch 不变，没有在 Mac 同名路径写入。
- 新增 `GitWorkspaceSSHTests`：实际 Windows backend、专用 master和远端临时库验证 Push/Delete、TAR/ZIP 选定 Ref 的二进制字节、literal path Reset index/worktree/HEAD、Stash Pop --index、Clean 两种目录开关、普通远端 FileTab Ignore 的最终保存。最初失败仅是本机 tar 提取参数把 `[]` 当 glob；修正为 `literal[[]1].bin` 后 1/1 通过，`/tmp/kero-p4-t9-ssh-final.log`。没有改产品迎合错误断言。
- 审计回送：F-01 Fetch/Pull 确认标签 `385cf50`；F-02 Reset File 自身保存被当作过期，Red `/tmp/kero-p4-t9-reset-red.log` → `dd4535e`，覆盖脏 Tab 保存/同标签重读、准备失败、外部 stale 在保存前拒绝、准备期间 index 改变拒绝。F-03 已交付 Tag Archive 旧文档 `811835a`，计划按真实 Rename 再编辑回归同步按需 HEAD 查询。F-05/F-06 Tag 默认目标与检查失败仍进入 Push，真实原生表单/bare remote Red `/tmp/kero-p4-t9-tag-red-final.log` → 4/4 Green `/tmp/kero-p4-t9-tag-green.log`，提交 `2e5bb4c`；先审查记录再修复，未新增执行器。
- 上述 Reset/真实 SSH 回归后的完整 `KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test` 为 **214/214、0 failures、0 skipped**，`/tmp/kero-p4-t9-full.log`（Tag 新增回归及其修复在这次运行之后，须再跑最终全量；不冒称214覆盖了后改代码）。

## P4-T8（本轮：具体 Stash）

- 初始 Red `/tmp/kero-p4-t8-red.log`：缺 Stash 列表、解析及具体对象动作。原独立计数命令被同一快照中的 NUL 分隔 `stash list` 取代，count 仅从条目派生，查询失败保留上一次完整快照。没有双缓存、按需加载器或新轮询。
- `GitStashActionTests` 首轮 8/8（`/tmp/kero-p4-t8-green.log`）：临时真实库验证指定非栈顶 Apply/Pop、两种 `--index`、Branch 检出/恢复/成功移除、Drop 精确移除，外部移位拒绝 Pop/Drop/Branch，固定 OID Apply 不误用新 selector；冲突保留 index/reflog。
- `GitStashDialogTests` 2/2（`/tmp/kero-p4-t8-native.log`）：原生默认字段/名称校验和具体 selector/OID；真实 sheet Cancel 不写入，确认勾选 Reinstate Index 后从第二条恢复工作区/index并仅移除第二条。
- 新增第九个用例覆盖准备保存失败、切工作区拒绝与清除旧列表。第一次全量运行中该测试把空根目录误当作应完成 Git 状态解析的目录，等待条件超时；依据 `sync(root: "")` 源码改为等待在途操作结束，不修改产品、不加任意等待、不跳过测试。失败记录仍在 `/tmp/kero-p4-t8-all.log`。
- STASHES 行复用 `TreeRowSurface` 的高度、字体、命中和 hover；原生右键与辅助功能动作指向所选条目。Pop Latest 捕获首条 selector/OID，使用同一表单；删除无参盲 `stashPop`、旧计数状态和无引用的旧菜单字符串。
- 最终 `GitStashActionTests` 9/9、完整 Windows SSH 参与的 `make test` 210/210（0 failures、0 skipped），`/tmp/kero-p4-t8-all-final.log`；`make build` 与严格签名通过，`/tmp/kero-p4-t8-build.log`。整包安装后正式 PID40825 不变，提交 `111f3cd`。本机 `/tmp/kero-p4-ui.sN0hKI` 和 Windows `/tmp/kero-p4-ui-remote-7uQn4y` 只是下一项的专属临时 UI fixture，尚不是完整路径验收；独立探测 master `/tmp/kp4-ui-AF5B7F61.sock`，非用户连接。

## P4-T7（本轮：未提交改动、目录与 Ignore）

- 接手时 `GitUncommittedActionTests.swift` 已暂存；保持原样、不夹入本轮原子提交。初始筛选测试实际编译失败，缺 `resetUncommitted/cleanUntracked/stageEntries/unstageEntries` 及带 message/target 的 Stash，完整 Red 位于 `~/Library/Application Support/rtk/tee/1792005139_make_tes_7339ac.log`。
- 用户随后明确要求此前的 staged 内容也入库，已独立提交 `GitUncommittedActionTests.swift`；该文件在最终 210 项完整测试中 4/4 通过。此前“不夹入本轮实现提交”仅说明当时的保护边界，不再表示该测试仍未入库。
- 同一 `perform` 实现 Message/Include Untracked、Mixed/Hard、永久 Clean；共享标题原生菜单加入仅菜单项，保留 hover，目录从原始分组一次批量执行并包含 Rename 两侧。原逐文件 Trash/SSH 审核路径未替换。
- Ignore 使用普通 FileTab，等待原读取任务，TextKit 末尾插入、独立撤销组和串行保存；特殊字符按字面转义，CRLF/已有脏文本保留。文件排他创建前后检查发起目标，失败不覆盖或宣称已忽略。原生缓冲未就绪时使用同一 FileTab 文本，旧 reload 表面不能覆盖新文本。
- `GitUncommittedActionTests` 4/4，`GitWorkspaceActionTests` 3/3；`GitWorkspaceMenuTests` 初轮 3/3，补真实 sheet Cancel/Confirm → stash Git 持久结果后 4/4；FileTab 远端暂停读取/失败保存回归通过。
- `KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`：198/198、0 failures、0 skipped（包含真实 Windows pinned/automatic interactive rebase），日志 `/tmp/kero-p4-t7-all.log`。最后修改后原生 4/4 复验 `/tmp/kero-p4-t7-native-final.log`。
- 这里只证明 Integration/NativeUI 和上述真实 SSH 变基路径；全对象右键、VoiceOver 和 Uncommitted 真实 SSH 全 App E2E 继续归 T9，不以测试数量冒称完成。

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

## P4-T3（本地分支与 Archive）

- 源码执行链：`RecentCommitsView` 本地 Branch/`+N` 菜单 → 发起窗口的 `GitPanel.presentBranchAction`/`GitBranchDialog` → 唯一 `GitStatusModel.perform`（原有互斥、仓库/机器/选中 Ref OID 校验、Git argv）→ 本机登录环境/所选 SSH backend。旧 P2 `createReference(.branch)` 已删除，现存 `createLightweightTag` 明确归 P4-T5 替换；文件编辑保护继续复用 `Project.saveBeforeGitAction` 与 `reloadAfterGitAction`。
- 隔离真实 Git：历史与顶部 Branch 创建/替换，Rename 不覆盖，安全/Force Delete，非 HEAD 定向 Push；至少 3 个 bare remotes 的中途服务器拒绝与部分删除成功，Normal、Force With Lease、Force、多个远端默认上游和末次成功 upstream；ZIP/TAR 实际条目和原始字节。模拟 SSH backend 证明有界读取、超 64 MiB 拒绝不破坏已有目标、远端临时清理失败准确报告路径；**不冒称已从真实 Windows SSH GUI 导出 Archive**。
- 后续补足 T3 核对：服务器上目标 Branch 已消失时，不需要另外创建本地 ref 清理执行器；临时 bare remote 的真实 `push --delete` 已清除**相应**的 remote-tracking ref，而另一 remote 同名 ref 仍在。首个 Push 被拒时后续 remote 仍未写入；前导 `-` 分支名被 Git 校验拒绝；另一个 worktree 检出的 Branch 不被 `branch -f` 强制覆写。这三项回归最终进入同一个 `GitBranchActionTests`。没有为了初始静态猜测保留无用 fallback。
- 原生 `GitBranchDialogTests` 验证 Name/Check out、Rename、Force Delete 默认关闭、Set Upstream 默认开启、Push Mode 默认 Normal、Remote 多选、全部取消选择时主按钮禁用；无 remote 时面板显示明确原因且不能提交，不再空点击。整套 Kero 内嵌右键、系统 NSSavePanel 手动操作及真正 SSH Archive 下载的 E2E 仍归 P4-T9；低层成功不等于这些用户路径已验收。
- 原始验证：`/tmp/kero-p4t3-deep3.log`（初期 8 项）、`/tmp/kero-p4t3-remote-fixture.log`（9 项）、`/tmp/kero-p4t3-missingref-red-20261014.log`（追加 12 项，实际均 Green）、`/tmp/kero-p4t3-complete-20261014.log`（151 项、0 失败、1 个真实 SSH 环境跳过），`/tmp/kero-p4t3-complete-build-20261014.log`（Debug 构建、严格验签 PASS）。追加边界验证后 `/tmp/kero-p4t3-final-154-20261014.log` 完整 154 项、0 失败、1 环境跳过；最终修复无 remote 空点击后，`/tmp/kero-p4t3-final-155-20261014.log` **155 项、0 失败、1 环境跳过**，`GitBranchActionTests` 12/12、`GitBranchDialogTests` 3/3。最终独立 Debug `make build` 以 `/tmp/kero-p4t3-final-build-20261014.log` 为准。

## P4-T4（远端分支操作与真实 SSH 回归）

- 新增 `GitRemoteBranchActionTests` 13 项真实临时 Git + 多 bare remote 回归：最长已配置 remote 名称前缀、符号 `origin/HEAD` 对比真实名为 `HEAD` 的 Branch、Checkout tracking / 本地同名分流、Fetch/Force Fetch/其它 worktree 拒绝、Merge 和 Pull No-FF/Squash、选中 Ref 变更拒绝、部分 Checkout 后 Pull 失败、远端不存在时只清理同 remote tracking，以及服务器保护策略拒绝仍保留引用。每项核对 Git 的 refs/HEAD/index/worktree，不是只测 argv。
- 直显和 `+N` Remote Branch Badge 都接入同一原生菜单。原生 `GitBranchDialogTests` 核对 Checkout 名称、Force Fetch 默认 off、Pull No-FF/Squash 默认 off。原生集成的真实右键→窗口操作和完整 SSH Remote Branch E2E 仍需 P4-T9 单独验收，不用 fixture 冒充。
- **拒绝跳过真实 SSH**：普通 `make test` 不设置 `KERO_P4_TEST_SSH_HOST` 会按测试源码产生 1 skipped；本轮使用 `KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test` 完整执行，专用 Windows 主机经独立严格 host-key 的 SSH 连接确认。真实 `GitInteractiveRebaseTests` pinned/automatic 均在 Windows 临时 repo 验证 TTY、编辑器与 Git HEAD；该项在最终完整回归中 **passed（68.810 秒）**，不借用已有用户 SSH master。单项实机先前也在 `/tmp/kero-p4-ssh-required-20261014.log` 通过（46.883 秒）。
- 首次带真实 SSH 的完整回归 `/tmp/kero-p4-full-ssh-no-skip-20261014.log`：169 项、0 skipped，但 `GitExternalRefreshTests` 的提交刷新等候超时，导致 2 条失败。独立该类 2/2 通过。第二次全量 `/tmp/kero-p4-full-diagnostic-ssh-20261014.log`：169 项、0 skipped，Git 外部刷新与 Windows SSH 均通过，但 `WorkspaceWindowCloseTests` 旧宿主 release 断言超时。独立重现诊断 `/tmp/kero-windowclose-diagnostic-20261014.log` 明确：旧 SwiftUI NSHostingView 仍被保留，而新宿主、当前 NSWindowDelegate 和 TerminalManager 窗口身份**都正确**。
- 因此没有修改生产 Git 轮询或靠提高 6 秒门限掩盖失败。独立修复测试生命周期错误的提交 `a6f28be`：Git 刷新窗口改用真正可成为 Key Window 的原生类型；窗口关闭测试验证新宿主/Delegate 接管和最终保存/关闭，不对 SwiftUI deinit 时序强作保证。修正后单项 `WorkspaceWindowCloseTests` 1/1 与 `GitExternalRefreshTests` 2/2 均通过。
- **最终正式全量结果**：`/tmp/kero-p4-t4-verified-full-windows-20261014.log`，**169/169、0 失败、0 跳过**，含真实 Windows SSH 和 P4-T4 的 13 项集成测试；`/tmp/kero-p4-t4-verified-build-20261014.log` 对应 `make build`、严格 `codesign --verify --deep --strict` PASS。此前失败日志保留作为历史依据，不谎称它们通过。已明确区分真实 SSH 交互式 Rebase 的 E2E 与待 P4-T9 核对的 Remote Branch 完整 UI/SSH E2E。

## P4-T5（Tag 创建、详情、删除、Push、归档）

- 原代码仅在 Commit 上用单个名称输入框创建轻量 Tag，Tag Badge 只提供 Show Commit/Copy。现统一到 `GitTagDialog` 的原生 Add Tag（默认 Annotated，说明可空，切换类型不清空说明、单/多远端可选）、Delete（默认本地，仅明确选择一个远端才删服务器）、Push（单/多远端选择、默认正常）、Tag Details（含签名校验、只读可复制全文）与共享 Archive；直显 Badge 和 `+N` 调相同菜单。旧 `presentGitNameDialog`、`presentCreateReferenceDialog` 与 `CommitReferenceKind` 兼容路径在本 task 删除，不新建另一个 Git 执行器。
- 测试根因：原 `testTagDeleteRemoteFirstAndPreservesLocalWhenRemoteRejects` 认为 `receive.denyDeletes=true` 拒绝 Tag 删除。隔离真实 bare remote 实测该配置**仍允许 Tag 删除**；手写到 `hooks/pre-receive` 的测试 Hook 又被用户全局 `core.hooksPath` 覆盖。此测试修复为在**测试 bare repo 自身**显式 `core.hooksPath`，由临时 Hook 确实拒绝 refs/tags 删除，确认失败时 Tag 的本地、远端对象均存在；解除测试 Hook 再删除，双方 refs 均不存在。并未为错误测试假设改变产品逻辑。原失败 `/tmp/kero-p4t5-tag-model-test-20261014.log`，修后通过 `/tmp/kero-p4t5-tag-delete-green-20261015.log`。
- 真实临时 Git `GitTagActionTests` **7/7**：Annotated/Lightweight 与创建附注、Replace 但保护其它 Tags、两端远端删除顺序与拒绝、Push 首错停止、不调用 Fetch 的远端可达启发式、创建后立刻用实际新 Tag object OID 推送、从较老 Annotated Tag 导出的 ZIP 不混入当前 HEAD 新文件，以及临时生成的 SSH 签名 Tag 缺可信 allowedSignersFile 时标明 `unverified` 而非 `valid`。`GitTagDialogTests` **3/3**：原生默认值、类型切换保留文本、重名后输入保留、单多远端选择和无远端禁用。独立的 `AppSettingsTests` 还覆盖 `git.always-proceed-push-tag` 默认/保存/重置，与 Checkout consent 独立。
- **含真实 Windows SSH 的完整 XCTest 本轮通过**：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，日志 `/tmp/kero-p4t5-full-windows-20261015.log`，**179/179、0 失败、0 跳过**；SSH pinned/automatic 专用案例通过（34.334 秒）。`make build` 通过且严格签名，日志 `/tmp/kero-p4t5-build-20261015.log`。`/Applications/Kero.app` 已整包安全替换并重新验签/校验二进制 SHA256 `6aa389b1f7fd93aa9a6d1eec1b3d88bbd00ae28a3716435be4194a2eb0a4d52d`，现有 Kero PID 69689 未退出也未重启。
- 边界：SSH 这次验证的是**真实 Windows Interactive Rebase**，Tag 部分证明了真实临时 bare remote Git 副作用与原生弹窗组件，Tag 完整用户右键→确认→真正 Windows remote 的 App E2E 仍须在 P4-T9 单独验收；不能用上述 179/179 冒充已完全部 E2E。

## P4-T6（历史文件右键、只读版本、比较和 Reset）

- 接手现场只有部分 `DiffTab.Source`、历史 Rename 定位器和新测试，尚未迁移 `DiffTab.reload`、`Project.openCommitDiff`、`SessionStore`、`RecentCommitsView` 的菜单与真正 Git 写入口；初始 `make test ONLY_TESTING=KeroTests/GitHistoryFileTests` 证实缺 `commitHash/staged` 编译错误，不把前人的计划记录当作已实现。
- 同 task 源码真源清理：删除 `DiffTab.staged/commitHash/commitParentHash/commitStatus` 等散落 optional/Bool 状态，使用一份 `Source` 区分 `.worktree/.staged/.commit/.revision/.revisionWorktree`。`Project.findDiffTab` 根据来源区分标签，`SessionStore.ContentSnapshot.diff` 直接保存 Codable Source 并恢复；只读历史原文使用同一 TextKit 表面而不是把全部行染成新增。
- 根因复现：`git diff --find-renames` 用提交与**已被工作区修改**的文件比较时，可能因相似度下降无法确认 Rename。现在优先查询提交→worktree，查不到时按需查询提交→HEAD 的已提交 Rename，最后核对远端／本地 backend 中新路径真实存在，不预建全历史索引。相关真实 Git/native test 已通过。
- 历史文件右键沿 `RecentCommitsView` 单行菜单绑定来源窗口/仓库，打开工作区文件只使用当前 Project/backend；Reset 通过原生 NSAlert 明确 SHA、路径和 index/worktree 覆写，再经唯一 `GitStatusModel.perform` 执行 `git --literal-pathspecs checkout <SHA> -- <path>`；额外校验确认前捕获的该文件 index+worktree blob OID，外部 CLI 修改后拒绝过期确认。二进制 Git 恢复真实字节，不错误要求可显示 UTF-8。
- 仅在用户展开历史 Commit 时一次读取该提交的 Git `--numstat -z`：按 NUL 解码重命名、二进制状态；已知二进制的历史行禁用文本查看/比较，不禁用 Reset。状态属于既有 GitStatusModel，仓库切换即失效，SSH 不按文件逐个请求。
- 专项 `GitHistoryFileTests` 已由初期编译 Red 走到 8/8 Green（`/tmp/kero-t6-binarymetadata-test.log`）：原生只读／空文件／5MiB／二进制、Root/Deleted、历史重命名与动态工作区刷新、SessionStore 三模式还原、Reset 二进制 index/worktree 与 HEAD 不变、过期内容拒绝、展开后二进制 Rename 元数据。一手失败日志 `/tmp/kero-t6-takeover-red.log`、`/tmp/kero-t6-rename-fix.log` 均保留，不谎称最初通过。
- 第一次全量（`/tmp/kero-p4t6-full-realssh.log`）实际执行 187 项（含 Windows SSH），唯一失败是 `DiffTabTests` 旧的未跟踪符号链接读取：Git 对索引和 HEAD 都返回“在磁盘上存在，但不在相应 Git 对象中”，新实现当成真实读取失败而清空 symlink 显示。独立临时 Git 仓库复现四种 Stage/HEAD 不存在语义，修复 `DiffTab.gitContent` 的严格 missing 分类，未吞掉网络/权限读取错误；专项回归 `/tmp/kero-p4t6-symlink-regression.log` 转绿。保留失败日志，不把第一次测试冒称通过。
- **最终全部验收**：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，日志 `/tmp/kero-p4t6-verified-full-ssh.log`，**187/187，0 失败，0 跳过**；Windows pinned/automatic 实际交互式 Rebase 用例通过（28.477 秒），GitHistoryFileTests 8/8、DiffTabTests 16/16、SessionStoreTests 6/6 均通过。`make doctor` 通过，日志 `/tmp/kero-p4t6-doctor.log`；构建日志 `/tmp/kero-p4t6-verified-build.log` 记录独立 Build 和严格签名。T6 的完整鼠标右键、保存对话框和真正远端文件恢复仍归 T9 实机 E2E，不能用上述 lower-layer/NativeUI 部件测试冒充。
