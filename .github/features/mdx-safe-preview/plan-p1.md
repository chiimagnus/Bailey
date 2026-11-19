# P1｜静态 MDX 文件预览

交付一个源码可编辑、静态内容可阅读、动态内容明确不执行的 MDX 文件标签。

## 方案

沿 `Project.openFile`、`FileTab`、`FileViewerView` 复用 Markdown 预览核心，
只在扩展名和 AST 内对 JSX、ESM、表达式做额外判断。
MDX 是编译到 JavaScript 的格式，不能按字符串正则剥离 `import` 和花括号后假装完整渲染。
使用明确的 AST 内容边界：静态 Markdown 节点使用安全渲染器；执行性节点保留可识别的源表示。
File 主菜单仍由 `BaileyApp.swift` 的单个 `⌘⇧V` 命令负责，不重复注册。

## 任务

<a id="p1-t1"></a>
### P1-T1 MDX 识别与静态可读节点

- **位置**：`FileTab` 文件类型路由、Markdown 渲染 AST、`FileViewerView` 和宿主测试。
- **实施**：支持 Markdown/GFM、Front Matter 和静态 HTML/JSX 白名单，ESM/import/JSX 表达式保留为不执行的可读代码片段；
  错误在相应位置呈现，不删除用户源码、组件标记或表达式。
- **验证**：带 import/export／组件 props／表达式／嵌套 JSX 的 MDX、仅 Markdown 的 MDX、无效 JSX 语法；
  禁止自动执行、外部资源访问，严格校对展示与原文的对应关系。

<a id="p1-t2"></a>
### P1-T2 单标签显示与系统 File 菜单

- **位置**：`BaileyApp.swift` 已有 File 视图切换命令、`WorkspaceWindowModel` 当前活动文件、`WorkspaceDockView.projectTabMenu`。
- **实施**：MDX 使用与 Markdown 相同的源码／预览／并排动作和原生动态灰显，不能注册第二个快捷键。
- **验证**：文件前台与后台、编辑／预览焦点、其它 Dock 组、多窗口／关闭／恢复；任何状态均能安全回源码。

## 阶段验收

宿主解析／安全验证、Bailey Dev 原生菜单和真实编辑 GUI；不得把原型“可显示一部分”称为完整 MDX 支持。
