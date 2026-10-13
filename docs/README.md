# Kero 文档

本目录维护当前实现及开发约束。开始修改前先读 [AGENTS.md](../AGENTS.md)，本地开发从 [development.md](development.md) 开始。

每页只负责一件事，并有明确的更新时机。文档与实现冲突时先查源码、配置和验证结果；修正过时说明，不能把计划当成已经具备的能力。改动使文档失效时，在同一提交中更新。

## 核心文档

| 文档 | 职责 | 什么时候更新 |
| --- | --- | --- |
| [architecture.md](architecture.md) | 分层、状态所有权、装配、窗口和目录边界 | 所有者、依赖方向或文件归属改变 |
| [standards.md](standards.md) | Swift、命名、并发、注释、简化与性能原则 | 开发约定或平台基线改变 |
| [testing.md](testing.md) | 唯一完成标准、测试层次、回归选择、性能测量与人工验收 | 测试入口、覆盖范围或验收要求改变 |
| [development.md](development.md) | 环境、本地构建与安装、依赖和生成资源 | 工具链、构建入口、依赖或生成方式改变 |
| [release.md](release.md) | CI、版本、打包和发布流程 | workflow、版本规则或分发方式改变 |
| [signing.md](signing.md) | 签名身份、证书、权限与验证 | 签名配置、证书或打包验证改变 |
| [ui.md](ui.md) | 主题、共享组件、字体、交互、无障碍和本地化 | 视觉规则、组件、交互或文案体系改变 |

## 功能文档

每页先写 `Invariants`：修改此功能不能破坏的约束。随后解释所有权、行为、失败与恢复以及验证入口；不以源码清单代替说明。

| 文档 | 负责什么 | 什么时候更新 |
| --- | --- | --- |
| [projects.md](features/projects.md) | 项目身份、添加、工作范围和切换 | 项目或面板范围改变 |
| [ssh.md](features/ssh.md) | 远端身份、后端、断线和重连 | 连接、远端操作或目标绑定改变 |
| [dock.md](features/dock.md) | 自由停靠、标签、焦点与窗口生命周期 | 布局、移动、关闭或动作路由改变 |
| [terminal.md](features/terminal.md) | Shell、终端表面、输入、查找与通知 | 终端生命周期或输入输出改变 |
| [files.md](features/files.md) | 共享文件树、创建、重命名与删除 | 树行或文件操作改变 |
| [editor.md](features/editor.md) | 文件缓冲、自动保存、重载和文本编辑 | 读取、编辑、保存或高亮改变 |
| [git.md](features/git.md) | 仓库状态、命令执行、提交与草稿 | Git 操作、刷新或执行环境改变 |
| [diff.md](features/diff.md) | 差异读取、原生渲染、编辑与重挂载 | Diff 数据、布局或保存改变 |
| [browser.md](features/browser.md) | 浏览器标签、导航和开发服务入口 | WebView、地址处理或导航改变 |
| [command-palette.md](features/command-palette.md) | 命令面板、本机文件搜索与会话定位 | 搜索、选择或命令接入改变 |
| [settings.md](features/settings.md) | 偏好、配置文件和即时应用 | 设置项、配置读写或默认值改变 |
| [session-restore.md](features/session-restore.md) | 窗口快照、恢复和终端历史 | 持久化内容、格式或恢复行为改变 |
| [tunnels.md](features/tunnels.md) | 长期 SSH 隧道的配置和生命周期 | 转发、认证或监听规则改变 |

## 根目录入口

[README](../README.md) 面向用户，负责能力、安装和使用；[CONTRIBUTING](../CONTRIBUTING.md) 负责贡献流程；[SECURITY](../SECURITY.md) 负责漏洞报告和安全范围；[NOTICE](../NOTICE.md) 负责来源与第三方声明。AI 开发规范只维护根目录的 `AGENTS.md`。

## 文档维护

1. 先确定受影响功能及其文档，核对真实入口、状态所有者和最终结果，再修改规则。
2. 一个事实只在一个位置详细维护。入口、贡献指南和 PR 引用它，不复制命令清单、测试矩阵或整段约束。
3. 新增、移动、合并或删除页面时，同步更新本索引、入口和所有现行引用。功能页必须给出不变量、更新时机和验证入口。
4. 当前进度、阻塞和下一步保留在既有任务真源；需求和非目标保留在需求文档；失败试验保留在实施证据。已有 `.github/features/<功能>/` 使用 `idea.md`、`todo.toml`、`plan-pX.md` 分别维护需求、任务状态和实施路径，不另建同义看板。
5. 已停止或暂缓的路线不能被旧文档重新列成待办。完整历史不改写；值得防止重复踩坑的教训提炼成有原因、适用范围和验证方法的长期规则。
6. 区分已实现、已验证、已安装和已发布；没有实测的结果明确标注。全部文档核对不等于已经完成全源码审计。

本体系采用 Tinycast 的“短入口 → 核心职责 → 功能不变量 → 贡献与验收”组织方式，参考来源见 [NOTICE](../NOTICE.md#文档体系来源)。
