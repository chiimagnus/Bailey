# Neon 本地运行时

Bailey 保留 [kylemacomber/Neon 固定提交](https://github.com/kylemacomber/Neon/tree/ce8d252c8fd53ea0b6960e02c423315eef11f141) 中实际使用的 Tree-sitter 高亮核心，以原有 Neon 包身份接入 Xcode。版权与 BSD 3-Clause 许可见 [LICENSE](LICENSE)，原文也随 App 分发。

本地改动修正异步解析返回的失效范围，移除当前平台不再需要的兼容接口和未使用的查询／样式路径。不能只把依赖 URL 换成新版 [Neon](https://github.com/ChimeHQ/Neon)：其 API 与当前固定版本不同，升级前必须验证编辑、取消、嵌入语法与可见颜色。

补丁细节、依赖更新与回归入口由[开发文档](../../docs/development.md#neon)维护，不在此复制实现或测试清单。升级时保留许可证，并同步核对 App 中分发的副本。
