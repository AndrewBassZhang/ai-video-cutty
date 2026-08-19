# AI Video Cutty

AI Video Cutty 是一款社区维护、优先本地运行的 macOS 媒体预览工具：从 Finder 选中本地视频、音频或图像后，可通过 Finder 服务在独立预览面板中查看、定位、标记和导出。

> 本项目由社区维护，与 Apple 或 OpenAI 没有隶属、背书或赞助关系。

## 一键下载并打开安装盘（推荐）

可使用下列命令下载最新版 DMG 并直接打开安装盘：

```zsh
curl -fL https://github.com/AndrewBassZhang/ai-video-cutty/releases/latest/download/AI-Video-Cutty-macOS.dmg -o "$HOME/Downloads/AI-Video-Cutty-macOS.dmg" && open "$HOME/Downloads/AI-Video-Cutty-macOS.dmg"
```

1. 将 `AI Video Cutty.app` 拖到 `Applications`（应用程序）图标。
2. 首次启动时按住 Control 点按应用，选择“打开”，再在确认框中选择“打开”。
3. 需要精确 A/B 裁切导出、原码流音频导出或更丰富元数据时，可在 DMG 中主动运行可选的 FFmpeg 安装器；它不使用 Homebrew 或 `sudo`。

## 功能概览

- 从 Finder 打开一个已选中的本地普通文件，也可在启动时传入本地文件路径。
- 使用 macOS 框架预览视频、音频与可解码图像。
- 提供播放、循环、A/B 标记、逐帧、穿梭播放、时间线缩略图、音频波形、音量控制和可调播放速度。
- 显示原生媒体与图像元数据；安装 `ffprobe` 后可获得更丰富的媒体元数据。
- 可旋转或镜像当前视频、图像视图，并将这些显示变换写入新导出的文件。
- 通过用户主动安装的外部 FFmpeg 精确导出 A/B 视频或音频片段。
- 在目标容器支持时，不经重新编码导出音频码流。
- 支持图像裁切保存、JPEG 转换和 JPEG 压缩。
- 将可自定义的预览快捷键保存在本机用户默认设置中；`⌘S` 始终保留给 Finder 入口。

## 系统要求与可选组件

- macOS 13 Ventura 或更高版本。
- 从源码构建需要 Xcode Command Line Tools，以及与 Swift 6 包清单兼容的 Swift 工具链。
- 普通预览不需要 FFmpeg；A/B 裁切导出和原码流音频导出需要 FFmpeg；`ffprobe` 为增强媒体元数据的可选组件。

应用包不包含 FFmpeg 或 `ffprobe`。可选安装器将下载的两个外部可执行文件安装到 `~/Library/Application Support/AI Video Cutty/bin`；应用先查询该用户管理目录，再查询标准系统位置及启动环境的 `PATH`。为兼容旧安装，当新目录中没有可用程序时，应用会继续查询旧目录 `~/Library/Application Support/Finder Media Preview/bin`；新安装不会写入该旧目录。

## 从源码构建与测试

克隆仓库后，在仓库根目录运行：

```zsh
git clone https://github.com/AndrewBassZhang/ai-video-cutty.git
cd ai-video-cutty
swift build -c release
swift test
```

若 Apple Silicon 机器的终端运行在 Rosetta/x86 环境，请改为原生执行测试：

```zsh
arch -arm64 swift test
```

构建可分发的应用包：

```zsh
Scripts/build.sh
```

脚本会生成 `build/AI Video Cutty.app`，将中文使用说明和可选 FFmpeg 安装脚本复制进应用包，生成 `AppIcon.icns`，并进行仅供本地使用的 ad-hoc 签名。每次运行都会重建该应用包。

应用包生成后，可创建“拖入应用程序”安装盘：

```zsh
Scripts/package_dmg.sh
```

该脚本输出 `dist/AI-Video-Cutty-macOS.dmg`，并会拒绝覆盖已有的 DMG。

## 安装说明

### 使用本地构建

1. 运行 `Scripts/build.sh`。
2. 将 `build/AI Video Cutty.app` 拖入 `/Applications`。
3. 启动应用一次，再在 Finder 中选中一个本地媒体文件。

原型构建使用 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。若 macOS 阻止首次启动，请按住 Control 点按应用，选择“打开”，再在确认框中选择“打开”。绕过系统警告前，请自行审阅源码与应用包。

### 使用 DMG

1. 打开 `AI-Video-Cutty-macOS.dmg`。
2. 将 **AI Video Cutty.app** 拖到 **Applications**。
3. 首次启动时按住 Control 点按 **Applications** 中的应用，选择“打开”，再在确认框中选择“打开”。该原型使用 ad-hoc 签名，尚未公证。
4. 使用 Finder 服务前请重新打开应用。DMG 同时提供 `安装说明.txt`、`使用说明.md`、第三方声明与可选 FFmpeg 安装器。

## 访达服务与快捷键设置

安装并至少启动一次应用后：

1. 在 Finder 中选中一个本地媒体文件。
2. 从 **Finder > 服务** 调用 **显示 AI Video Cutty**。
3. 若要指定或恢复 Finder 快捷键，请打开 **系统设置 > 键盘 > 键盘快捷键 > 服务**，找到 **显示 AI Video Cutty** 并设置快捷键。预期的 Finder 快捷键为 `⌘S`；请在 Finder 位于前台时测试。

应用会在自己的快捷键编辑器中保留 `⌘S`，避免可配置的应用内操作遮蔽 Finder 入口。Finder 服务仅接受本地普通文件，并使用第一个符合条件的已选文件；目录、网页 URL 与额外选中的文件不会批量打开。

## 当前默认快捷键

除专属 Finder `⌘S` 入口外，下列默认快捷键均可在 **AI Video Cutty > 设置…** 中修改。

| 操作 | 默认快捷键 |
| --- | --- |
| 播放 / 暂停 | `Space` |
| 关闭预览 | `⌘Q` |
| 后跳 / 前跳 5% | `⌘←` / `⌘→` |
| 倒向穿梭 / 暂停 / 正向穿梭 | `J` / `K` / `L` |
| 设置 A / B 标记 | `I` / `O` |
| 从开头重新播放 | `R` |
| 切换循环 | `P` |
| 清除 A/B 标记 | `X` |
| 静音 / 取消静音 | `M` |
| 重置视频或图像缩放 | `0` |
| 暂停视频时逐帧 | `←` / `→` |
| 播放视频时临时穿梭 | 按住 `←` / `→` |
| 降低 / 提高音量 | `↓` / `↑` |

不带修饰键的方向键为专属传输控制。播放视频时，松开按住的左或右方向键会恢复之前选择的正向播放速度。

## 可选、外部且明确触发的 FFmpeg

打开或查看媒体不需要 FFmpeg。精确 A/B 裁切导出与原码流音频导出需要 FFmpeg；`ffprobe` 可补充媒体元数据。若缺少任一工具，应用会显示安装选项；不会静默安装任何内容。

仅当您主动打开打包的安装器，或在应用中选择 **安装 FFmpeg…** 时，安装器才会运行。它将外部 `ffmpeg-static b6.1.1` 运行时下载到 `~/Library/Application Support/AI Video Cutty/bin`，不请求管理员权限、不使用 Homebrew 或 `sudo`，也不在应用包中附带二进制文件。默认传输地址为 `https://cdn.npmmirror.com/binaries/ffmpeg-static/b6.1.1`；仅在连接或 HTTP 请求失败时，才回退到固定上游发布地址 `https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1`。两个下载的 gzip 资源必须通过固定 SHA-256 校验；摘要不匹配会立即停止，不会再回退。

外部运行时采用 GPL-3.0-or-later 许可证。准确来源、许可证链接、资源名称和摘要见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。您也可以自行安装 FFmpeg；安装后请重新打开应用以刷新可执行文件检查。

## 隐私与离线行为

核心预览、编辑、元数据回退和文件保存流程均在本地执行。当前审阅的应用代码中没有账号登录、遥测客户端、云上传或远程媒体处理路径。该原型唯一包含的联网流程是上述由用户主动触发的外部运行时下载。

Finder 服务通过 Finder 粘贴板接收所选文件的 URL。自定义快捷键保存在本机用户默认设置中。媒体文件从本地路径读取，只会在您主动选择导出或保存时写入。具体写入与外部工具边界见 [SECURITY.md](SECURITY.md)。

## 限制

- 媒体播放和解码能力取决于已安装 macOS 版本提供的编解码器；不支持的格式可能无法打开。
- 应用一次只打开一个符合条件的 Finder 选中项；它不是批量浏览器或媒体库管理器。
- 精确 A/B 裁切导出会重新编码视频和音频，不是源文件的逐字节副本。
- 原码流音频导出会尽量保留音频包，因此 A/B 边界按音频包对齐而非逐采样精确；所选目标容器也可能拒绝源编解码器。
- 图像裁切保存提供明确的 **覆盖保存** 选项；该操作会替换源文件且不创建备份。需要保留源文件时，请使用 **另存为新文件**。
- 该原型使用 ad-hoc 签名，尚未公证。

## 后续方向

以下是可能的社区方向，并非发布承诺：

- 为分发构建提供 Developer ID 签名与公证。
- 提供已记录的编解码器支持矩阵和更清晰的不兼容诊断。
- 增加辅助功能与真实 Finder 服务端到端测试覆盖。
- 建立正式发布流程、带版本的发行说明和漏洞报告联系人。

## 文档

- [架构说明](Docs/ARCHITECTURE.md)
- [DMG 安装说明](Docs/安装说明.txt)
- [中文使用说明](Docs/使用说明.md)
- [第三方声明](THIRD_PARTY_NOTICES.md)
- [贡献指南](CONTRIBUTING.md)
- [安全策略](SECURITY.md)
- [行为准则](CODE_OF_CONDUCT.md)
- [更新日志](CHANGELOG.md)

## 许可证

AI Video Cutty 采用 [MIT License](LICENSE)。
