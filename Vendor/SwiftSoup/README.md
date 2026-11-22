# SwiftSoup

保留 [SwiftSoup 2.14.4](https://github.com/scinfu/SwiftSoup/tree/8397a860c6955924b584c50c5265c6aac0970015)
的库目标与原始许可证。本地补丁在分词器合并实体和普通文字时保留原始 UTF-8 区间，
并通过 `TextNode.originalTextSegments()` 提供给 Bailey 的 Markdown 阅读器。

升级时核对 SwiftSoup 是否已公开等价区间；有则移除本地副本。验证重复 HTML 文本、实体、非 ASCII
字符及嵌套 Markdown 容器中的回源定位和部分复制。
