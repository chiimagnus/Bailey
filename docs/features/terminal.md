# 终端

终端会话承载用户的 Shell 和 CLI 工作。本页负责进程、原生表面、输入与查找；
相应行为或 Ghostty 集成改变时更新。

## Invariants

- **一个会话拥有一个长生命周期进程与表面。** SwiftUI 重绘、切换项目或移动标签不重新启动 Shell。
- **切换保留上下文。** 选区、滚动、查找和后台命令不能因为原生视图重挂载而丢失。
- **关闭仅结束明确关闭的内容。** 测试和安装不能中断用户正在运行的 Bailey 或其中任务。
- **重启不能恢复进程。** 终端历史回放只恢复输出，不恢复正在执行的命令。
- **显示会话与接收输入分开。** 选中的终端标签、活动 Dock 组和 Ghostty 实际键盘接收者不是同一状态；
  Find 临时接管时不改变后台 Shell 身份。

## 入口与输入

通过标签栏「＋」或「新建终端」创建会话；仅添加项目目录不会创建 Shell。
新终端使用项目固定目录或显式传入的目录，不继承其他终端的路径。
SwiftUI 转发交互，AppKit／Ghostty 负责输入与原生焦点。
会话直接拥有 Ghostty 表面；命令完成只记录递增计数，供 Files 和 Git 刷新。焦点错误应修复路由或重挂载，不以重建表面绕过。

Finder 文件或目录落在**本机** Ghostty 终端正文时，由该终端原生拖放接收：按 Shell 语法转义绝对路径，
多项以空格分隔，只插入输入缓冲，**不发送 Return**。
文件名含 CR/LF、ESC 或其它终端控制字符时整批拒绝，不能只靠 Shell 引号防止模拟按键。
固定 SSH 终端从创建之初就是远端目标（即使连接尚未握手），
动态 SSH 在进程仍存活／断线时也不接受 Mac 文件 URL；
用户自行启动的前台系统 `ssh` 进程即使未被 Bailey 接管，同样拒绝；
`exec ssh` 替换根 Shell 且保留 PID 时也按进程真实可执行文件判别。
真正退出返回本地 Shell 后恢复本机路径拖放。拒绝的拖动不得回落到父级普通文件打开或隐式上传。
终端文件链接同样只在本机 Shell 中解析 Mac 路径；SSH 会话不把远端路径解释成本机文件。
右键打开文件时再次确认当前终端与原项目归属；普通网页链接仍可使用。

交互式 Git 变基创建独立终端，在目标仓库运行真正的序列编辑器，不占用已有会话。
SSH 先通过现有 helper 建立该终端自己的连接，再使用 Ghostty 原生启动输入发送命令，
不等待 OSC 或猜测 prompt；工作目录以纯文本八进制表示，避免文件名控制字符被终端当按键执行。
主题更新和重挂载不重发启动输入。SSH 会话结束后保留结果直到用户按 Enter 关闭，
专用远端标签不转为本机工作区。

终端使用[共享查找浮层](find.md)，Ghostty 负责屏幕和滚动历史中的匹配、高亮及导航；
终端输出不提供替换。快捷键不能与 Shell 输入或标签切换互相抢占，窗口规则见 [dock.md](dock.md)。

查找栏关闭后，只恢复当前前台活动组中仍由可见宿主承载的原终端；
恢复许可属于工作区交接，Find 输入框与 Ghostty 的实际焦点仍归原生控件，
不能仅凭 selected 标签或窗口指针尝试恢复。停车区虽保留同窗口挂载，却不是可恢复的输入目标；
旧宿主的延迟布局、卸载和焦点请求也不能改写新宿主的表面状态。

延迟聚焦及全选同样核对来源组；重挂载时保留查找状态，不把消失回调误当关闭并抢回终端输入。

## 主题与配置

字体、配色、光标和 Option-as-Alt 通过所属窗口应用到现有表面，不重新创建进程。
终端与周边界面的主题从同一来源解析，见 [ui.md](../ui.md#主题与共享值)。

## 通知与历史

通知的会话归属、系统呈现与 Bark 推送见 [notifications.md](notifications.md)。

终端历史持久化默认关闭，启用后单独保存；其中可能包含敏感内容，不默认采集或提交。
恢复方式见 [session-restore.md](session-restore.md)。

## 验证

检查多项目、多标签、双窗口、拖动、关闭、重挂载和主题改变后的输入与 Shell 身份；
通知专项见 [通知](notifications.md)。
`WorkspaceIdentityTests` 覆盖本机／固定 SSH 握手前后、断线和动态 SSH 返回本机的文件 URL 接收资格，
并核对 Shell 特殊字符与控制字符拒绝；真实 Finder→Ghostty E2E 核对终端输入和源文件字节，
不能仅凭返回 `.copy` 当作已成功插入或已执行命令。

`NativePaneRetentionIntegrationTests` 在最小原生宿主中验证终端停车、重挂载、查找、
Shell PID 和回调释放；`WorkspaceRetentionUITests` 在完整 Bailey Dev 中核对跨标签 Shell PID，
以及真实 Finder 文件拖入 Ghostty 后仅插入转义路径、不自动回车、不额外创建文件标签。
`GitInteractiveRebaseIntegrationTests` 直接附着原生终端表面验证真实 PTY 与独立 SSH 会话，
Git Graph 的实际用户操作由 `GitDialogUITests` 验证。
真实 CLI 通知、快捷键及重启恢复按 [testing.md](../testing.md#人工回归) 单独记录。

实现入口：[TerminalSession.swift](../../Bailey/Terminal/TerminalSession.swift)。
升级 Ghostty 还需执行 [dependencies.md](../dependencies.md#依赖与本地补丁) 的回归。
