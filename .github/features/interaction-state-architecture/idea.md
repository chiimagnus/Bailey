# 列表交互状态与打开行为统一

## 背景

Bailey 的 Files、Git Changes/Graph、Projects、Dock 和临时列表分别在模型、View 与 AppKit 输入入口维护焦点、
选中、打开、展示、悬停、右键及多选。前次共享视觉改动曾错误侵入原生 Settings 侧栏；这次必须从状态的所有者和
动作入口重构，不能再靠逐行覆盖颜色修补。已有 `context-menu-and-tree-selection` Feature 的 P1 菜单反馈
仍有未完成验收，不能将它当作已解决，也不能平行复制菜单路由。

## 用户目标

1. 对照 VS Code **实际源码与真实交互**：区分键盘 Focus、Selection、范围 Anchor、当前 Display、
   Hover、菜单 Context Target、打开 Open、Dock Activation、原生 First Responder。
2. 每一个可见视觉状态必须由真实状态驱动：活动/失焦选中背景、弱展示背景、焦点描边、
   悬停与临时右键描边不能互相误代；编辑控件的原生输入不可被列表抢占。
3. Files 单击、双击、方向键、Space/Return、⌘/Shift 多选、紧凑目录各段和菜单命令需与经核验的
   VS Code 交互一致；本机/SSH 的文件路径和项目范围不得混淆。
4. Git Changes/Graph 复用通用键盘输入接收与共享树行视觉，但分别维护仓库、Diff、提交、
   Stash 的合法局部状态，不混入 Files 多选模型。
5. Projects 和 Dock 复用共享视觉意图，保留自身激活/展示/关闭与未保存保护；
   Command Palette、Tab Switcher 使用与其用途相符的游标/预览，不建全局状态机。
6. 逐条真实调用链迁移：同 task 清理被替代的老路径、更新所属长期文档、测试并原子 Git 提交；
   plan/todo 仅本地跟踪，提交 SHA 回写 todo。

## 不变量与非目标

- 一个状态只有一个领域所有者：Files 属于 `FileTreeModel`，Git Changes/Graph 属于对应面板，
  Dock 属于 `DockWorkspaceModel`，原生键盘属于 key window 的 firstResponder。
  不新增全 App FocusManager、全局 SelectionStore、额外事件总线或兼容双轨。
- 文件打开必须有显式用户事件；仅移动 Focus、悬停、展开、右键不打开文件。
  不丢失未保存编辑；SSH 远端失败不得回退本机；项目/机器/连接身份需要校验。
- **Settings 窗口是原生 SwiftUI List，完全排除共享高亮迁移**，保持 `9c84d355` 的回撤决定。
- VS Code 的 DOM/Electron、WebKit、预览标签生命周期、全局 context key/service 架构
  不可机械照搬；只有在当前 Bailey 交互目标确实需要且行为证据明确时才改变 UX。
  不为了“模块化”增加抽象层；优先减少重复实现。
- 已有 `context-menu-and-tree-selection` 未完成的 P1 菜单蜂鸣/瞬时反馈继续由原 Feature 追踪；
  新任务触及同一链时先对照其 todo 与审计，避免重复工作或假报完成。

## VS Code 源码参考（2026-10-27 main: 4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e）

- `src/vs/base/browser/ui/list/listWidget.ts`：
  `Trait/SelectionTrait/TraitSpliceable`、`KeyboardController`、`MouseController`、
  `DefaultStyleController`、`getContiguousRangeContaining`；
  独立 Focus/Selection/Anchor、跨 splice 的身份保留、Mac ⌘/Shift 手势、
  不连续多选的 Shift 重算、Active/Inactive/Context 的独立样式。
- `src/vs/base/browser/ui/tree/abstractTree.ts`：
  树节点、展开、Focus/Selection/Anchor 及稳定 identity provider 的分层。
- `src/vs/platform/list/browser/listService.ts`：
  选择变化不是打开命令，`onDidOpen` 路由保留 focus/pin 选项。
- `src/vs/workbench/contrib/files/browser/views/explorerView.ts`：
  `getContext(true)`、`onDidOpen`、`onContextMenu`；
  右键集合外先选中目标、集合内保留多选，右键选择不派发打开。
- `src/vs/workbench/contrib/scm/browser/scmViewPane.ts`：
  SCM 列表局部选择、焦点和资源操作动作目标，不能无条件继承 Explorer 的多选行为。
- `src/vs/workbench/browser/parts/editor/editorGroupView.ts`：
  活动编辑器、所选编辑器、固定标签及组激活不同事实。
- `src/vs/workbench/contrib/files/browser/fileActions.ts`：
  从 Explorer Context 解析文件动作对象，而不是从当前编辑器猜目标。

上述源码通过 GitHub 读取；实现时仍需沿实时 Bailey 调用链核对，不能把上游引用当作测试结果。

## 验收范围

- 输入：单击/双击、空白行、右键/Control+点击、拖动、方向键/Space/Return/Esc、
  ⌘点击开关选中、Shift 点击/Shift+方向键、⌘A、菜单按键；
  空列表、单行、成百上千项、深层/紧凑目录、路径特殊字符/Unicode。
- 状态：空选、单选、多选/不连续选、不同 Anchor、焦点在集合内/外、
  菜单集合内/外、活动/失焦/窗口切换、悬停重叠、重命名与新建输入期间、
  显示旧文件、目录折叠/展开、重命名/删除、刷新与重建。
- 业务：Files、Git Changes、Git Graph、Projects、Dock、
  Palette/Tab Switcher；含本机/SSH、跨项目、跨窗口、Diff/Editor/Terminal 真实焦点，
  合法/失效命令目标和未保存保护。
- 视觉：默认及自定义 Ghostty 主题，明/暗、中/英、字号与窄/宽布局、
  hover/selection/focus/context 的复合像素与无障碍。
- 环境：当前 macOS/Xcode 独立 Dev 构建、宿主 XCTest、隔离 App E2E；
  macOS 15.6 真机、触控板等环境若不可取得，记录具体缺口而非冒称完成。
  不退出/替换运行中的正式 Bailey，不覆盖用户真实剪贴板/SSH master。
