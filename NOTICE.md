# 来源与第三方声明

Bailey 使用 [GNU GPLv3](LICENSE)。本页用于定位项目来源、文档参考和仓库中已有的第三方声明，
不替代各组件的许可证原文，也不构成完整的依赖许可审计。依赖或资源来源变化时同步核对。

## 项目来源

本项目 fork 自 [benjaminv/kero](https://github.com/benjaminv/kero)，最初来源于
[egoist/kero](https://github.com/egoist/kero)，现独立维护。保留原作者及后续贡献者的版权和署名。

## 文档体系来源

文档组织与维护方式参
考 [abue-ammar/tinycast](https://github.com/abue-ammar/tinycast/tree/808f2d8792474fac3608217c6e14708e947182fd/docs)
及同一修订
的 [AGENTS.md](https://github.com/abue-ammar/tinycast/blob/808f2d8792474fac3608217c6e14708e947182fd/AGENTS.md)。

采用其核心文档分工、功能页 `Invariants`、文档索引中的职责与更新时机、
单一完成标准以及贡献与验证衔接。正文按 Bailey 当前实现重新编写，不复制 Tinycast 的产品能力、
性能数字、签名密钥、渠道或贡献者法律条款。

## 已有第三方材料

| 材料 | 来源或声明 |
| --- | --- |
| 原生行号索引所承继的 STTextView 本地源码 | [保留原许可证与署名](Bailey/Resources/Licenses/LICENSE-sttextview-source.txt) |
| Tree-sitter 语法与查询资源 | [来源与固定版本](Vendor/BaileyGrammars/README.md)、[原 MIT 许可证](Vendor/BaileyGrammars/LICENSE) |
| Neon 核心运行时 | [来源与裁剪范围](Vendor/Neon/README.md)、[BSD 许可证](Vendor/Neon/LICENSE)；同一原文随 [App 资源](Bailey/Resources/Licenses/LICENSE-neon.txt) 分发 |
| Material Icon Theme 图标 | [来源与固定提交](Bailey/Resources/MaterialFileIcons/NOTICE-material-icon-theme.txt)、[许可证原文](Bailey/Resources/MaterialFileIcons/LICENSE-material-icon-theme.txt) |
| JetBrains Mono 字体 | [OFL.txt](Bailey/Resources/Fonts/OFL.txt) |
| Nerd Fonts 资源 | [LICENSE-nerd-fonts.txt](Bailey/Resources/Fonts/LICENSE-nerd-fonts.txt) |
| Ghostty 及 Swift 包依赖 | [Package.resolved](Bailey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) 记录来源和解析提交；许可证随各依赖源码维护 |
| TSX 本地解析器 | 来源、固定修订和更新边界见 [development.md](docs/development.md#语法解析与-diff) |

升级依赖或重新生成资源时，保留原有许可证与版权文本；自有文档整理不翻译、覆盖或删减这些原文。
补丁的行为与验证由 [development.md](docs/development.md#依赖与本地补丁) 维护。
