# Textual 本地运行时

来源：[Textual 0.5.0](https://github.com/gonzalezreal/textual/tree/01b51875a5406eefc95f52a058cb059e7bc94dc4)，保留 App 使用的 `Sources/Textual`，不复制上游示例和测试。
原始 MIT 许可见 [LICENSE](LICENSE)，App 内继续分发许可副本。

本地修复文本选择层在预览滚动、切换标签后不更新命中布局的问题。
修复位于 `TextSelectionInteraction` 与 `LiveTextLayoutCollection`，维持链接点击和选区复制，不新建第二种渲染器。
验证与升级要求统一见[本地开发](../../docs/development.md#依赖与本地补丁)。
