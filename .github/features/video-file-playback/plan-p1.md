# P1｜在现有 FileTab 中播放视频

交付视频文件默认渲染与系统播放器控制，不改变 Dock 或 Finder 的文件入口。

## 方案

沿 `Project.openFile` → `FileTab` → `FileViewerView` 路由视频；原文本／图片内容保留。
本机媒体以文件 URL 交给 `AVPlayer` / `AVPlayerView`，不通过 `WorkspaceBackend.read(maxBytes:)` 加载全部 bytes。
播放器由唯一 FileTab 持有，Dock 只是展示；不为一次文件打开创建第二层面板或应用级播放管理器。

## 任务

<a id="p1-t1"></a>
### P1-T1 媒体路由与可信资源处理

- **位置**：`FileTab.Content`、`FileTab.readContent`、`FileViewerView`、本机文件类型测试。
- **实施**：识别可播放容器及 Mac URL；读取轨道、时长与播放错误；远端路径不转本地；无效资源不阻止普通 FileTab 关闭。
- **验证**：MP4/MOV/M4V、HEVC/H264 等实际系统可解码文件、损坏容器、无音轨、符号链接、文件改名／删除、未知扩展名。

<a id="p1-t2"></a>
### P1-T2 原生视频区和聚焦控制

- **位置**：新增视频播放视图、Dock 的文件标签生命周期及 `docs/features/editor.md`。
- **实施**：适合窗口、进度、播放、暂停、音量、全屏；仅播放器聚焦时 Space／方向键有效；离开标签默认暂停。
- **验证**：实际 GUI 观看和音频输出、窗口缩放、Dock 移动／复位、关闭、前后台切换、双视频标签不叠加声音。

## 阶段验收

`make build:ui`、受影响宿主测试和隔离 Bailey Dev，检查真实解码而不是“呈现一个视频框”。
