# P1｜文件标签原生音频播放

交付可打开、播放、暂停和定位的本机音频文件标签，不需要新建独立工具面板。

## 方案

入口仍是 `Project.openFile` → `FileTab` → `FileViewerView`。
扩展文件类型的懒加载与展示路由，媒体 URL 是只读本机 `file://`，不通过 `WorkspaceBackend.read(maxBytes:)` 把完整音频载入内存。
AVFoundation 的 `AVPlayer` 生命周期归对应文件标签；只在需要时实例化，在真正关闭时释放。旧文本和图像路径不回归。
图形按钮、焦点与快捷键遵循 `docs/ui.md`，播放控制不写项目级“任务状态系统”。

## 任务

<a id="p1-t1"></a>
### P1-T1 媒体类型判定与安全加载

- **位置**：`FileTab` 内容路由、`FileViewerView`、本机文件 URL / 文件状态检查。
- **实施**：基于 macOS 可实际播放的资源判定，不仅看扩展名；支持本机播放与错误占位；SSH 路径不回退读取同名本机路径。为媒体保持文件身份、重命名和取消加载语义。
- **验证**：合法 MP3/M4A/WAV/AIF/CAF、无效 codec、损坏头、零字节、只读路径、符号链接及文件变动。

<a id="p1-t2"></a>
### P1-T2 原生播放控件与生命周期

- **位置**：新增音频播放内容视图、`PaneContent` 文件标签状态及 `docs/features/editor.md`。
- **实施**：播放、暂停、定位、时间、音量、速度及详情。关页终止；切其它 Dock 组不重新创建 AVPlayer；键盘 Space 只作用真实播放器焦点。
- **验证**：实际 macOS 音频输出、设备变动、切窗、项目切换、多个音频文件、播放完毕与错误恢复，源文件不变。

## 阶段验收

`make build:ui`、受控宿主 AVFoundation 测试、隔离 Bailey Dev 播放与焦点，明确哪些编码由系统不支持而非 Bailey bug。
