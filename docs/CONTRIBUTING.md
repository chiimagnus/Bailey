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

涉及树结构、路径或展开状态时，运行真实文件系统检查：

```sh
xcrun swiftc -swift-version 5 -o build/check-file-tree-navigation \
  kero/Workspace/WorkspaceBackend.swift kero/Workspace/TreeDisplayModel.swift \
  kero/Workspace/FileTreeModel.swift \
  scripts/check-file-tree-navigation.swift && build/check-file-tree-navigation
```

涉及行布局、点击或按钮时，再运行原生鼠标事件检查：

```sh
xcrun swiftc -swift-version 5 -o build/check-tree-row-hit-testing \
  kero/Workspace/TreeDisplayModel.swift kero/UI/Sidebar/TreeRowStyle.swift \
  scripts/check-tree-row-hit-testing.swift && build/check-tree-row-hit-testing
```

第二项在屏幕外的原生窗口中测试共享行，不安装或注册另一份应用。
两项检查覆盖结构和命中范围，但不能代替视觉、焦点与真实操作验收。

## 真机验收

代码改动须将签名 Debug 构建安装到 `/Applications/Kero.app`，检查受影响行为：

1. 替换前确认没有会丢失的运行命令或未保存编辑，再正常退出 Kero。
2. 安装并重新打开，确认原有项目、标签与终端布局恢复。
3. 实际操作受影响路径，记录结果；不要把编译通过或事件发送成功当成验收通过。
4. 删除临时应用、独立测试配置和安装备份。

文件树改动要一起检查文件面板、Git 未提交、暂存和提交历史：

- 高亮范围内的缩进、上下边缘和留白都能触发行操作；右侧按钮只执行自身动作。
- 长名称可横向滚动，操作按钮不移动；窄侧栏和放大字体下仍可用。
- 压缩目录打开真实末级目录，状态颜色、提示和无障碍描述一致，没有独立状态字母列。
- 大树滚动保持响应，选中、悬停和竖线布局一致。

仅修改文档时，核对事实、链接和引用命令，不为验收另建应用副本。

## 提交前

- 一个提交只包含一个已验证的逻辑改动，不夹带其他人的修改。
- 说明改了什么、为什么这样改，以及实际运行的检查；未验证部分单独列明。
- 行为变化同步更新对应文档；本地化规则见[本地化](LOCALIZATION.md)。
- 运行 `git diff --check`，确认没有无关改动或临时产物。
