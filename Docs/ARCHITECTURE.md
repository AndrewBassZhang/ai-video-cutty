# 架构说明

## 目的与范围

AI Video Cutty 是单目标的 macOS SwiftPM 可执行程序。当前架构选择小型、本地运行的 AppKit 应用，而非服务或守护进程：Finder 提供一个已选中的本地文件，应用显示预览面板，可选导出流程只创建用户指定的本地输出文件。

本文档映射当前源码树，说明实现边界；它不是运行时安全认证，也不承诺 API 稳定性。

## 系统视图

```text
Finder 选中文件或本地启动参数
        |
        v
AppDelegate / LaunchInput / ServiceInput
        |  验证本地普通文件
        v
MediaRoute（UniformTypeIdentifiers + ImageIO 预检）
        |
        +-------------------+-------------------+
        |                   |                   |
        v                   v                   v
     视频 / 音频            图像               不支持
        |                   |                   |
        v                   v                   v
 AVFoundation + AVKit    ImageIO            正常结束
        |                   |
        +---------+---------+
                  v
       PreviewController + AppKit 视图
                  |
        +---------+----------+
        |                    |
        v                    v
   本地预览 / 界面       明确的导出 / 保存
                              |
                 +------------+-------------+
                 |                          |
                 v                          v
       ImageIO 临时写入              外部 FFmpeg `Process`
```

## 源码布局

| 路径 | 职责 |
| --- | --- |
| `Package.swift` | 声明 macOS 13 SwiftPM 可执行目标及其测试目标。 |
| `Sources/MediaPreview/App.swift` | 应用生命周期、Finder 服务入口、媒体路由、面板与控制器组合、播放状态、快捷键存储、图像保存行为、FFmpeg 计划与进程，以及应用级导出编排。 |
| `Sources/MediaPreview/TimelineView.swift` | 自定义 AppKit 时间线、波形提取/显示、播放器与图像缩放界面、音量控制、A/B 标记绘制及相关视图计算。 |
| `Sources/MediaPreview/CropEditor.swift` | 裁切预设、变换后画布几何、显示变换、交互裁切视图及裁切编辑页。 |
| `Sources/MediaPreview/Metadata.swift` | 图像元数据解析、原生 AVFoundation 媒体元数据回退、可选 `ffprobe` 增强及展示格式化。 |
| `Tests/MediaPreviewTests/` | 媒体路由、布局、导出计划、变换、元数据解析、键盘行为和保存安全决策的 XCTest 覆盖。 |
| `Scripts/build.sh` | 构建发布可执行程序，组装本地应用包，嵌入说明与安装器，并进行 ad-hoc 签名。 |
| `Scripts/install_ffmpeg.sh` | 用户主动启动、在终端可见的外部 FFmpeg 安装流程；不使用 Homebrew 或 `sudo`。 |
| `Scripts/package_dmg.sh` | 将已有应用包打包成不会覆盖既有文件的拖拽安装 DMG。 |

## 应用界面组成

### 入口与 Finder 集成

`AppDelegate` 是 AppKit 入口，支持两种本地输入：

- `LaunchInput` 规范化文件系统路径或 `file:` 启动参数，并拒绝非文件 URL。
- `showMediaPreview(_:userData:error:)` 接收 Finder 服务粘贴板。`ServiceInput` 读取 URL 对象，再选择第一个解析为本地普通文件的 URL。

`presentPreview(for:)` 对文件路由、构造 `PreviewController` 并放置 `PreviewPanel`。面板可见框优先使用第一个检测到的屏幕，随后回退到 `NSScreen.main`，最后使用固定回退框。本地键盘事件监听器仅在预览面板活跃时路由预览按键，从而保留编辑页与设置界面的文本输入。

### 预览控制器与自定义视图

`PreviewController` 持有所选 URL、媒体类型、`AVPlayer`、视图层级、播放状态、A/B 标记、显示变换、保存/导出界面和清理逻辑。它组合了：

- `ZoomablePlayerSurface`：封装 `AVPlayerView`，用于视频/音频展示、缩放、平移和显示变换。
- `ZoomableImageSurface`：用 `NSImageView` 展示具有相应缩放、平移和变换能力的图像。
- `TimelineView`：显示播放头、A/B 标记、视频缩略图和音频波形数据。
- `VerticalVolumeControl`、传输按钮、速度控制、导出状态与顶层说明/快捷键操作。
- `ShortcutSettingsWindowController`：由本机用户默认设置中的 `ShortcutStore` 支持。

控制器将不带修饰键的方向键视为专属传输/音量控制。可配置绑定与其分离；`⌘S` 会被应用内快捷键存储拒绝，以保留给 Finder 入口快捷键。

## 媒体框架边界

### 统一类型标识与 ImageIO

`MediaRoute` 使用 `UniformTypeIdentifiers` 将本地文件分类为图像、音频、视频或不支持的类型。图像分类包含 ImageIO 解码预检，即使文件类型未被其他规则归类为图像，也能预览可解码图像。

`ImagePreview` 使用 `CGImageSource` 解码第一张图像并取得元数据。`ImageMetadata` 提取面向界面的文件格式、尺寸、颜色信息、EXIF/TIFF 相机信息和曝光字段。`ImageRasterExporter` 应用当前变换/裁切计划，并通过临时文件写入图像输出。

### 媒体播放框架（AVFoundation 与 AVKit）

视频和音频播放基于 `AVPlayer`、`AVPlayerItem`、`AVURLAsset` 和 `AVPlayerView`。控制器使用 AVFoundation 获取时长、发现轨道、精确定位、协调 A/B 循环、处理播放器项目结束事件、生成缩略图、生成裁切预览并回退读取原生元数据。

`TimelineView` 使用 AVFoundation 解码音频样本来显示波形。它刻意只作为界面辅助，而不是源编辑器或通用编解码器实现。

`VideoDisplayTransform` 表示用户请求的四分之一转与水平镜像。裁切坐标在变换后的显示画布上计算，因此裁切编辑器、预览和 FFmpeg 过滤器计划共享同一顺序：源方向规范化、用户旋转/镜像、再裁切。

### 元数据回退与可选 `ffprobe`

`NativeMediaMetadata` 使用 AVFoundation，因此即使没有 FFmpeg 或 `ffprobe`，基础媒体信息仍然可用。`FFprobe` 是可选增强路径：它通过 `Process` 启动 `/opt/homebrew/bin/ffprobe`，将 JSON 收集到临时文件，限制五秒超时和 2 MiB 输出上限；失败时回退到原生元数据。

## 导出与保存流程

### 视频与音频裁切

`ABTrimExportPlan` 验证有序的 A/B 时间范围。`FFmpegTrimExportPlan` 将其转换为确定的 FFmpeg 参数数组：

- 视频裁切导出使用 H.264（CRF 18）与 AAC 音频，并可包含当前旋转/镜像/裁切过滤器链。
- 精确音频裁切导出会根据所选输出类型编码为 AAC、MP3 或 WAV。
- 原码流音频导出使用 `FFmpegAudioExportPlan`，并在目标容器支持源音频时采用码流复制。A/B 码流复制边界按音频包对齐。

`FFmpegLocator` 搜索用户管理目录、标准可执行文件位置和继承的 `PATH`，`FFmpegAvailability` 通过 `-version` 验证候选程序。顺序是 `~/Library/Application Support/AI Video Cutty/bin`、仅用于兼容旧安装的 `~/Library/Application Support/Finder Media Preview/bin`、标准系统位置及 `PATH`。`FFmpegTrimProcess` 通过 Foundation `Process` 和参数数组启动选定的可执行程序，读取 `-progress pipe:1`，限制保留的标准错误文本，并在主 actor 上异步报告完成状态；它不使用 shell 命令字符串。

`NSSavePanel` 提供输出路径。启动 FFmpeg 前，控制器拒绝源路径和任何已存在的目标路径。FFmpeg 导出使用 `-n`，阻止 FFmpeg 覆盖既有文件。

### 图像保存

图像裁切保存进入 `CropEditorSheetController`，随后明确要求选择：

- **另存为新文件** 会生成带编号的同级路径，并拒绝源路径或已占用目标路径。
- **覆盖保存** 是唯一的源文件替换路径。它需要明确确认，并使用 `FileManager.replaceItemAt` 且不生成备份项。

JPEG 转换与压缩绝不覆盖源文件。它们在本地渲染，原子性写入临时文件，再移动至已通过冲突检查的目标。

## 状态与生命周期

每个运行进程只保留一个 `PreviewPanel` 和一个 `PreviewController`。若面板已存在，`presentPreview` 会重新定位并前置该面板，而不是再创建一个。关闭面板会移除键盘监听器、取消未完成工作、清理播放器观察器和图像生成请求、终止运行中的 FFmpeg 进程，并退出应用。

跨启动持久化的状态刻意很少：只有自定义键盘绑定存储在用户默认设置中。应用不维护媒体目录、监控文件夹、同步队列、登录会话或后台服务。

## 打包与分发

`Scripts/build.sh` 编译 SwiftPM 发布目标，组装 `build/AI Video Cutty.app`，将中文使用说明和 FFmpeg 安装器复制进应用包资源，并进行 ad-hoc 签名。`Scripts/package_dmg.sh` 使用 Applications 符号链接与说明文件暂存应用，验证应用签名，创建压缩只读 `AI-Video-Cutty-macOS.dmg`，并拒绝替换既有 DMG。

这是本地打包路径，不是已公证的发布流水线。Developer ID 签名、公证和公开发布来源证明仍属后续工作。

## 扩展指引

除非已有获批的设计变更，否则新增功能应保持在以下边界内：

- 保持用户主动触发、以本地文件为入口的模型。
- 保持 FFmpeg 外部安装，进程调用不经 shell。
- 保持明确的保存选择、源/目标冲突检查与临时写入清理。
- 尽可能添加纯逻辑测试；将手动 Finder/macOS 验证与 XCTest 证据分开记录。
- 当快捷键行为、媒体写入语义、外部进程发现或网络行为改变时，在 `README.md` 与 `SECURITY.md` 中记录。
