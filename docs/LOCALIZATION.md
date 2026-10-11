# 本地化

本文负责界面翻译的归属、占位符和验证要求。
应用维护英语（`en`）与简体中文（`zh-Hans`），开发语言仍为英语；这与仓库文档使用中文无关。

## 翻译现有文案

在 Xcode 中打开 `kero.xcodeproj`，编辑 `kero/Resources/Localization/` 下的字符串目录：

- `Git`、`Sidebar`、`Terminal`、`Workspace`、`Browser`、`Editor`、`Settings`：对应功能界面。
- `Interface`：应用菜单、命令面板、标签和窗口控件。
- `InfoPlist`：权限说明；`ServicesMenu`：Finder 服务。

保留 `%@`、`%lld` 等占位符、快捷键符号和产品名称。
移动文案所属目录时，同步修改 Swift 中的 `table`，避免查找错误。

交给外部译者时，可在 Xcode 的“产品”菜单导出本地化为 XLIFF，翻译后再导入，无需提供源码。

## 新增文案

始终指定所属功能的字符串表，不使用无归属的 SwiftUI 本地化键：

```swift
Button(String(localized: "Create New Branch…", table: "Git")) {
    createBranch()
}
```

API 需要资源类型时，使用 `LocalizedStringResource("…", table: "Interface")`。
占位符含义不明显时，用 `comment` 说明。使用完整句子，不拼接翻译片段；数量相关文案使用目录中的复数变体。

文件名、用户内容和终端输出不参与翻译：

```swift
Text(verbatim: file.path)
```

工程已启用字符串提取。新增文案后先构建，再翻译目录中的新条目。

## 验证

在 Xcode 的方案编辑器中，进入运行选项，分别设置应用语言和地区，检查英语与简体中文。
确认菜单、对话框、长文案、数量变化和无障碍名称都正确。

应用内可从“设置 → 外观 → 语言”选择语言，重新启动后生效。
“系统默认”遵循 macOS 的语言偏好，包括系统设置中的单独应用语言；不支持的语言回退到英语。
重启前先保存编辑并结束不能中断的命令。
