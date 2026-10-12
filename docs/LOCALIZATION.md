# 本地化

新增或修改界面文案、字符串表或语言切换时，保留以下约束。

应用维护英语（`en`）与简体中文（`zh-Hans`），开发语言为英语；自有文档使用中文。

## 文案归属

字符串目录位于 `kero/Resources/Localization/`：

- `Git`、`Sidebar`、`Terminal`、`Workspace`、`Browser`、`Editor`、`Settings` 对应功能界面。
- `Interface` 负责菜单、命令面板、标签与窗口；`InfoPlist` 负责权限说明，`ServicesMenu` 负责 Finder 服务。

始终指定字符串表；移动文案时同步 Swift 中的 `table`，不使用无归属的本地化键：

```swift
Button(String(localized: "Create New Branch…", table: "Git")) {
    createBranch()
}
```

需要资源类型时用 `LocalizedStringResource`。保留占位符、快捷键与产品名称；语义不明的占位符提供翻译说明。使用完整句子和复数变体，不拼接翻译片段。

文件名、用户内容和终端输出不翻译，使用 `Text(verbatim:)` 等明确表达原文的入口。新增文案先构建提取，再补齐目录中的翻译。

## 语言与验证

「系统默认」遵循 macOS 语言偏好，包括单独应用语言；不支持的语言回退英语。应用内切换语言需重启，不承诺恢复未保存内容，见[恢复约束](SETTINGS.md)。

分别运行英语与简体中文，检查菜单、对话框、长文案、数量变化与无障碍名称。占位符和表名检查通过不能代替界面验证。
