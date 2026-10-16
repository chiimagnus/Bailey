# Neon 核心运行时

来源为 [kylemacomber/Neon 的固定提交 ce8d252c8fd53ea0b6960e02c423315eef11f141](https://github.com/kylemacomber/Neon/tree/ce8d252c8fd53ea0b6960e02c423315eef11f141)，与当前锁定的 STTextView-Plugin-Neon 一致。版权和 BSD 3-Clause 原文保留在 [LICENSE](LICENSE)，同一原文随 App 资源分发。

这是 Kero 的本地运行时子集，不是另一个解析器或通用跨平台包。Xcode 以相同 Neon 身份替换远程包；SwiftTreeSitter、Rearrange 和插件版本不变。最低 macOS 14 与插件一致，Kero 的最低 macOS 15.6 不变。

仅保留 Kero 与该插件实际使用的高亮、token 和 TreeSitterClient 核心。未引入旧 NSTextView／UIKit 适配、未使用的 invalidation buffer、Region 别名或上游测试语法；回归继续进入 KeroTests。

相对上游的运行时改动限于：
- 返回已随排队编辑转换后的失效范围，而不是丢弃结果返回旧坐标。
- 使用当前平台的 MainActor／主队列能力，删除旧系统兼容桥及冗余可用性标记；必要队列断言保留。
- 使用已锁定 SwiftTreeSitter 0.25 的匹配序列，移除弃用游标及没有调用者的查询模式／便捷接口；保留后台匹配、主线程谓词和现有解析调度。谓词读取后再次校验请求版本。
- 删除无调用者的 noChange／样式叠加分支；当前 provider 始终以请求结果替换颜色。复制时清理行尾空白，不改其他核心算法。

其余核心实现按上游维护，不顺手翻译或重写。补丁行为、升级与验证归 [开发文档](../../docs/development.md#neon)；升级时同步核对源码许可证与 App 中的副本。
