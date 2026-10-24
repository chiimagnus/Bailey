# Bailey 测试金字塔重建

## 为什么重做

当前 `origin/main`（计划创建时为 `17615ff`）虽已建立独立 XCUITest Target，测试结构却**中间大、顶部也大**：按源码中的 `test*` 方法统计，Unit **86**、Integration **463**、完整 App UI **133**。这只是方法基线，不等于 Xcode 实际执行数或时间。

前一版计划只按 UI 文件归组，准备删少量用例，却把 463 个 Integration 方法的真实性和成本留到最后。前期的 Git Graph 简化也只让少量方法退出，完整 App 的昂贵测试仍在反复覆盖同一算法、同一默认值和同一 Git 副作用。此路线停止，不继承旧分支的未合并修改。

## 要建立的金字塔

1. **底层 Unit 是主力**：纯转换、解析、几何、状态规则、目标身份、输入边界及异常矩阵在内存中快速覆盖。每个 Unit 不得为了执行纯函数先创建 Git 仓库、临时目录、NSWindow 或 SSH 连接；测试的条件组合应主要在这一层。
2. **中层 Integration 只证明真实边界**：真实 Git/ref/index/bare remote、文件读写与失败、受控 SSH、AppKit/TextKit 2/IME、WebKit/Ghostty/PTY 原生组件和对象释放；用最小真实组件，不挂完整工作区。删除仅重复 Unit 规则或其它 Integration 结论的昂贵 fixture/流程，保留不可由纯数据证明的系统效果。
3. **顶层 UI E2E 要少**：真实 Bailey Dev 启动、系统菜单→原生 Sheet、快捷键/第一响应者、跨窗口、Finder/系统文件选择、Git Graph 真实命中/颜色、多级菜单、实际 Git/文件副作用等**独有跨层接线**。不能让每个配置、每种 OID、每个后端操作都重新启动 App。只有底层无法验证的用户路径可以留在 UI。

**设计目标：** 让完整 App UI 从 **133** 项降到约 **30–50** 项（具体数随独有系统行为的实际核对确定），而不是再次出现 133→127 或 21→21 的“简化”。不为达到数字强删独有风险：超过目标则公开每条不可替代的理由，继续寻找真正低成本的验证归属，不伪报金字塔完成。Unit/Integration 方法数量不是可以靠搬文件、拆分测试或删有效断言凑出的配比；最终还要比较同条件下真实 fixture/进程、GUI 启动次数及运行耗时。

## 范围与顺序

- **P1 Unit（86）**：先迁移误放在 Integration 的纯解析和模型状态测试，再重点检查 FileTabPersistenceTests 的 **22 项**、PanelContextTests 的 **10 项**无直接重型 IO 候选。逐方法排除间接系统调用与原生视图后，下沉真正的内存异步测试；消除错误的 Git/文件 setup，反向纠正 Unit 中真实 Bundle/IO 测试。候选数字不是已证实可移动数量。
- **P2 Integration（463）**：逐方法检查真实 Git/文件/Native/Remote 测试，只保留不可由 Unit 完成的协作合同；识别重复、重型 fixture 和共享工作区的伪集成，减少真实进程、窗口或等待，而不是只移动目录。
- **P3 Git UI（66）**：Git Dialog 21、Graph/Geometry 45，真正减少重复的完整 App 方法；每条删除有 P1/P2 已验证的替代。
- **P4 其他 UI（67）**：Git Changes/History 等 26，Files/Editor 22，Workspace 19；收敛真实用户入口，不重复底层错误矩阵。P3/P4 汇总核对全部 133 项原用例的去向。

## 不变约束

- 不改业务行为、UI/UX、原生 Sheet 及安全默认值；Git 写入必须仍检查项目/机器/HEAD/Ref/OID、保存保护和实际字节。纯重构仅动测试；若低层 Red 暴露真实产品 bug，另以最小根因修复与回归处理。
- 不新增 Test Target、Mock Git、全局焦点管理器、全量智能选择器、专用测试 App 或备用后端；可复用现有 Fake WorkspaceBackend 测状态，但真实 Git/文件合同必须使用真实隔离 IO。不要为了“更纯”复制逻辑到测试代码。
- 只在 `BaileyTests/Unit`、`BaileyTests/Integration`、`BaileyUITests` 的现有 XCTest 体系和 `Makefile` 中工作。本地人工选受影响测试，CI 仍全量；不使用 Peekaboo 代替 XCUITest。
- 测试不接触正式 `/Applications/Bailey.app`、真实用户仓库/SSH master、未授权网络。独占 Bailey Dev 的 GUI 焦点；计划任务分阶段小步验证、每个代码 Task 一个提交，立即删被替代的旧 helper/兼容路径。
- 本目录 `idea.md` 拥有需求，`todo.toml` 拥有状态，`plan-pX.md` 拥有实现；当前计划与审计默认只本地保存，不混入长期文档。现行测试职责变化时才更新 `docs/testing.md`，不将迁移期细节写入长期规则。

## 可核对的验收

- **完整映射**：原 Unit 86、Integration 463、UI 133 的每一方法都有当前真实执行依赖/职责；UI 的 133 项均有“保留或删除+确切低层/保留 UI 替代”归属。不得把 GitGraph 的真实颜色、文件 Tree 交互、TextKit/IME、PTY 或多窗口焦点降级为纯逻辑。
- **逐层实际减少成本**：Unit 不做磁盘/进程 setup；Integration 减少实测重复真实 I/O/窗口挂载/等待；UI 真正删掉冗余 App 启动和多次重复操作。按实施前后的**实际方法发现数、测试时长、启动/子进程次数**对比，无相同环境证据不报“提速百分比”。
- **验证完整**：全部适用的系统配置（默认/非默认、明暗、中英、字号、宽度）、输入（空、非法、Unicode、二进制、10k/100k、大量 lane）、状态（旧 Ref/OID、取消、并发、失败恢复、断线、重启、资源释放）及关键组合在**正确层**得到执行结果。未覆盖需逐项说明环境、原因、影响与补验，不因本地选择性测试通过就宣称 CI/所有系统全绿。
- **构建和收尾**：每 task 对应的 `make test:ClassA,ClassB` 通过；影响 UI 时 `make test:ui ONLY_TESTING=...` 必须有真实选中数和退出码；阶段/最终 `make build`、`make build:ui`、签名及本地/CI 全量门禁按 `docs/testing.md` 执行，不重复做无必要的整套 GUI。
- `macOS 15.6` 真机、物理触控板、外部显示缩放和获授权 SSH 缺位时按范围标记未测，不能虚构“全环境通过”。
