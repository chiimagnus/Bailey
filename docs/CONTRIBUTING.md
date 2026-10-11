# 开发与验证

本文负责本地构建、验收和提交要求。操作命令均从仓库根目录执行。

## 构建

需要 macOS 15.6+、Xcode，以及钥匙串中可用的 Apple Development 证书。
工程使用团队 `RDQHYSDFFG`；使用其他团队时，在 Xcode 中调整签名设置。
只有一个 Debug 应用：`Kero.app`，标识为 `sh.kero`。没有自动更新或发布流水线。

```sh
git clone --recurse-submodules https://github.com/chiimagnus/kero.git
cd kero
./scripts/prepare-ghostty.sh
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackageUpdates build
codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app
```

GhosttyKit 缺失时才下载，校验后保存在 `Vendor/GhosttyKit`，后续构建直接复用。
日常开发也可打开 `kero.xcodeproj`，按 ⌘B 构建。使用 Xcode 测试版时，可设置：

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

## 按改动选择回归检查

涉及停靠布局、标签顺序或恢复时，运行现有 Dock 模型检查：

```sh
xcrun swiftc -swift-version 5 -o build/check-dock-workspace \
  kero/Workspace/DockWorkspaceModel.swift scripts/check-dock-workspace.swift \
  && build/check-dock-workspace
```

涉及树结构、路径或展开状态时，运行真实文件系统检查：

```sh
xcrun swiftc -swift-version 5 -o build/check-file-tree-navigation \
  kero/Workspace/WorkspaceBackend.swift kero/Shared/Tree/TreeDisplayModel.swift \
  kero/Files/FileTreeModel.swift \
  scripts/check-file-tree-navigation.swift && build/check-file-tree-navigation
```

涉及行布局、点击或按钮时，再运行原生鼠标事件检查：

```sh
xcrun swiftc -swift-version 5 -o build/check-tree-row-hit-testing \
  kero/Shared/Tree/TreeDisplayModel.swift kero/Shared/Tree/TreeRowStyle.swift \
  scripts/check-tree-row-hit-testing.swift && build/check-tree-row-hit-testing
```

第二项在屏幕外的原生窗口中测试共享行，不安装或注册另一份应用。
两项检查覆盖结构和命中范围，但不能代替视觉、焦点与真实操作验收。

涉及文件打开、语法高亮、输入、Git 刷新、diff 或大树响应时，按[性能](PERFORMANCE.md)区分冷/热路径和用户可见阶段，记录前后测量与正确性回归。编译通过、骨架出现或 FPS 读数不能代替性能证据；没有测量时明确标记未测。

## 真机验收

代码改动须将签名 Debug 构建安装到 `/Applications/Kero.app`，检查受影响行为：

1. 替换前确认没有会丢失的运行命令或未保存编辑，再正常退出 Kero。
2. 安装并重新打开，确认原有项目、标签与终端布局恢复。
3. 实际操作受影响路径，记录结果；不要把编译通过或事件发送成功当成验收通过。
4. 删除临时应用、独立测试配置和安装备份。

如果正式 Kero 正在运行不能中断的终端命令，可先用同一个签名 Debug 包独立验收：

```sh
open -n -a "$PWD/build/DerivedData/Build/Products/Debug/Kero.app" --args --isolated-ui-test
```

该模式单独保存窗口和终端历史，不启动保存的 SSH 转发；字体、外观等全局设置仍可能共用，因此不要在隔离实例中修改设置。隔离验收不代替最终安装验收。

文件树改动要一起检查文件面板、Git 未提交、暂存和提交历史：

- 高亮范围内的缩进、上下边缘和留白都能触发行操作；右侧按钮只执行自身动作。
- 长名称可横向滚动，操作按钮不移动；窄面板和放大字体下仍可用。
- 压缩目录打开真实末级目录，状态颜色、提示和无障碍描述一致，没有独立状态字母列。
- 大树滚动保持响应，选中、悬停和竖线布局一致。

仅修改文档时，核对事实、链接和引用命令，不为验收另建应用副本。

## 提交前

- 一个提交只包含一个已验证的逻辑改动，不夹带其他人的修改。
- 说明改了什么、为什么这样改，以及实际运行的检查；未验证部分单独列明。
- 行为变化同步更新对应文档；翻译见[本地化](LOCALIZATION.md)，依赖升级见[依赖与生成资源](DEPENDENCIES.md)。
- 运行 `git diff --check`，确认没有无关改动或临时产物。

## 同步文档

自有长期文档放在 `docs/`，正文使用中文；`README.md` 与 `AGENTS.md` 入口保留在根目录。
命令、API、界面键和路径保持原样，上游文档、许可证和生成资源按[依赖规则](DEPENDENCIES.md)维护。

- 功能或操作入口变化：更新对应功能指南，并检查[使用指南](README.md)导航与上手步骤。
- 定位、项目范围或交互原则变化：更新[产品原则](PRODUCT.md)。
- 构建、验收或提交要求变化：更新本文；翻译方式变化：更新[本地化](LOCALIZATION.md)。
- 性能路径、缓存、调度、容量边界或测量方式变化：更新[性能](PERFORMANCE.md)。
- 依赖、补丁或生成流程变化：更新[依赖与生成资源](DEPENDENCIES.md)。
- 报告渠道或安全边界变化：更新[安全与漏洞报告](SECURITY.md)。

同一事实只详细写一次，其余入口链接到负责它的页面。移动文档时同步检查 Markdown、包说明和其他消费者中的引用。

功能文档按用户任务归属，不按源码文件拆页：

| 变化范围 | 文档归属 |
| --- | --- |
| 添加项目、SSH 连接要求、面板范围与断线 | [项目与 SSH](PROJECTS.md) |
| 终端命令入口、查找、分屏、焦点与关闭 | [终端与窗格](TERMINAL.md) |
| 文件操作、保存、查找替换、高亮能力与大小限制 | [文件与编辑器](EDITOR.md) |
| 状态表示、diff、暂存、提交、分支与远端操作 | [Git 与差异](GIT.md) |
| 网页操作、地址输入、开发服务打开方式 | [浏览器与开发服务](BROWSER.md) |
| 偏好、重启恢复与长期端口转发 | [设置与恢复](SETTINGS.md) |

功能文档说明当前行为，未实现的优化留在性能调查或实施计划中，不写成已上线能力。
