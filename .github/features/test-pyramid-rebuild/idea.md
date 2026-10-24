# Bailey 测试金字塔重建

## 为什么重做

当前 `origin/main`（计划创建时为 `17615ff`）虽已建立独立 XCUITest Target，测试结构却**中间大、顶部也大**：按源码中的 `test*` 方法统计，Unit **86**、Integration **463**、完整 App UI **133**。这只是方法基线，不等于 Xcode 实际执行数或时间。

前一版计划只按 UI 文件归组，准备删少量用例，却把 463 个 Integration 方法的真实性和成本留到最后。前期的 Git Graph 简化也只让少量方法退出，完整 App 的昂贵测试仍在反复覆盖同一算法、同一默认值和同一 Git 副作用。此路线停止，不继承旧分支的未合并修改。

## 真正的金字塔

此前只给 UI 设定 30–50 项目标，却几乎接受了 Integration 463 项不变，仍是**倒金字塔**。目标必须是 **大量 Unit、少量 Integration、极少 UI E2E**，也就是 Unit 显著多于 Integration、Integration 显著多于 UI，不能只在顶层做小修小补。

| 层次 | 唯一职责 | 入层门槛 |
| --- | --- | --- |
| **Unit：金字塔主体** | 纯规则、解析、几何，以及在**内存 WorkspaceBackend** 上隔离验证的 Model/ViewModel、actor 时序、Observation、目标身份、失败/重试状态 | 无真实 Git/磁盘/网络/NSWindow/完整 App；全部适用输入、异常与关键组合优先在这一层快速覆盖 |
| **Integration：少量真实边界** | 实际 Git ref/index/bare remote、文件系统/权限/保存、受控 SSH 与最小 TextKit/AppKit/IME/WebKit/Ghostty/PTY 组件 | 只有真实系统协作无法用 Unit 证明的合同才能留在这里；不重复纯规则矩阵或整套应用挂载 |
| **UI E2E：极少完整用户路径** | Bailey Dev 的真实菜单→Sheet、焦点、窗口交接、系统 Picker/Finder、图谱命中、多级菜单、最终 Git/文件结果 | 只有前两层仍无法证明的真实用户接线才能保留；不按字号、主题、OID、每种 Git 指令重复启动 App |

**结构验收不能只看 UI 减了多少。** 把 Unit/Integration/UI 大致 **70/20/10** 当作初步核查方向，**不是固定的 Apple / XCTest 配额**；真正的 Gate 是 Unit 成为绝大多数验证、Integration 明显精简、UI 极少。当前 86/463/133 必须从三层一起改变。完整 UI 的 30–50 项只是顶层工作目标，不能掩盖 463 项 Integration 的重构失败。达不到应逐项列出现有不可替代的真实合同并标记整体金字塔 **No-Go**，不凭新增空 Unit、虚删安全测试、合并超长 E2E 或改目录凑比例。

**根因是测试职责和生产业务判断与 IO 混在一起。** 先查真实控制流：能用已有内存后端运行的异步 Model/ViewModel 状态机应是 Unit；只有真实系统效果才是 Integration。如果 IO 包住了可独立验证的规则，就在**原业务所有者**抽出最小纯判断/状态转移，复用既有 API，不造新的 Manager/Mock Git/状态真源。Unit 覆盖全部策略矩阵，再用必要的真实系统 Integration 验证一次边界，最后 UI 验证一条实际前台用户链。不能靠文件搬迁或修改名称宣称层次改变。

## 范围与顺序

- **P1：做大真正的 Unit 底座。** 逐方法审查 **463 项 Integration** 的**间接**调用依赖，识别纯解析、用现有内存后端测试的状态机、被真实 Git/文件 IO 包住的业务决策及真正原生平台合同。原有 FileTab 的 22 项、PanelContext 的 10 项只是第一批静态候选，不是全部可以下沉的数量。
- **P2：大幅缩减 Integration，而不是沿用 463 项。** Git、Files/Editor、Workspace/Remote 各自把可枚举规则与真实 IO 分离，只保留确实必须执行的真实 Git、文件、TextKit/IME、PTY 和窗口组件合同；同任务删多余真实仓库初始化、重复窗口挂载及旧 helper。
- **P3：收敛 Git UI（66 项）**。Git Dialog 21、Graph/Geometry 45，真正删除重复完整 App 启动；保留独有 Sheet、危险确认、真实图谱命中与 PTY。
- **P4：收敛其余 UI（67 项）**。Git Changes/History 26、Files/Editor 22、Workspace 19，整体核销原来 **86 + 463 + 133** 项测试的最终责任层与可见结果。

## 不变约束

- 不改业务**语义**、UI/UX、原生 Sheet 及安全默认值；Git 写入仍检查项目/机器/HEAD/Ref/OID、保存保护和实际字节。以整理测试为主；只有源码确认业务判断与 IO 耦合、原有测试无法低成本验证时，才允许在**原所有者**做最小的无行为变化规则/状态抽取，并在同一 task 删除旧决策路径、核对 Integration 和 E2E。若低层 Red 发现真实 bug，单独按根因补回归，不以测试迁移掩盖。
- 不新增 Test Target、Mock Git、全局焦点管理器、全量智能选择器、专用测试 App 或备用后端；可复用现有 Fake WorkspaceBackend 测状态，但真实 Git/文件合同必须使用真实隔离 IO。不要为了“更纯”复制逻辑到测试代码。
- 只在 `BaileyTests/Unit`、`BaileyTests/Integration`、`BaileyUITests` 的现有 XCTest 体系和 `Makefile` 中工作。本地人工选受影响测试，CI 仍全量；不使用 Peekaboo 代替 XCUITest。
- 测试不接触正式 `/Applications/Bailey.app`、真实用户仓库/SSH master、未授权网络。独占 Bailey Dev 的 GUI 焦点；计划任务分阶段小步验证、每个代码 Task 一个提交，立即删被替代的旧 helper/兼容路径。
- 本目录 `idea.md` 拥有需求，`todo.toml` 拥有状态，`plan-pX.md` 拥有实现；当前计划与审计默认只本地保存，不混入长期文档。现行测试职责变化时才更新 `docs/testing.md`，不将迁移期细节写入长期规则。

## 可核对的验收

- **真实的金字塔形状**：逐一核对原 Unit 86、Integration 463、UI 133 方法的归属，**Unit 成为主要覆盖，Integration 显著小于 Unit，UI 显著小于 Integration**。记录全部原断言及新的 Unit/Integration/保留 UI 替代；发现仍然倒金字塔，不能把局部 P3/P4 减法标为整体 Go。
- **成本而不是搬运**：Unit 应没有真实磁盘/Git/进程/窗口前置，承载主要异常和并发矩阵；Integration 降低重复真实系统调用与组件挂载；UI 真正删除冗余 App 启动。除三层**方法数和占比**外，同时比较同条件运行时长、Git 子进程/仓库初始化/NSWindow 创建/GUI 启动次数。只搬方法、调名称、增无意义 Unit 或合并巨型 E2E 均不算加速。
- **验证完整**：全部适用的系统配置（默认/非默认、明暗、中英、字号、宽度）、输入（空、非法、Unicode、二进制、10k/100k、大量 lane）、状态（旧 Ref/OID、取消、并发、失败恢复、断线、重启、资源释放）及关键组合在**正确层**得到执行结果。未覆盖需逐项说明环境、原因、影响与补验，不因本地选择性测试通过就宣称 CI/所有系统全绿。
- **构建和收尾**：每 task 对应的 `make test:ClassA,ClassB` 通过；影响 UI 时 `make test:ui ONLY_TESTING=...` 必须有真实选中数和退出码；阶段/最终 `make build`、`make build:ui`、签名及本地/CI 全量门禁按 `docs/testing.md` 执行，不重复做无必要的整套 GUI。
- `macOS 15.6` 真机、物理触控板、外部显示缩放和获授权 SSH 缺位时按范围标记未测，不能虚构“全环境通过”。
