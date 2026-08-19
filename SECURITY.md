# 安全策略

## 安全状态

AI Video Cutty 是社区维护的原型。本文件记录当前从源码中观察到的安全边界；它不是已完成安全审计的声明，也不保证不受信任媒体一定安全。

当前仅支持最新的 `main` 分支源码版本。尚无受支持的预构建二进制发布版。

## 报告漏洞

请使用仓库的 [GitHub Security Advisories 私密报告表单](https://github.com/AndrewBassZhang/ai-video-cutty/security/advisories/new)。请勿公开提交 issue、发布概念验证媒体，或在维护者确认报告前披露可利用的文件路径。维护者目标是在七天内确认完整报告；修复时间取决于严重程度与可复现性。

报告请包含：

- 影响及受影响代码路径的清晰说明。
- 不暴露私密媒体或凭证的复现步骤。
- 相关的 macOS 版本、硬件架构及 FFmpeg/`ffprobe` 安装信息。
- 仅在您有权分享时，提供经过脱敏的最小测试文件或创建方法。

## 信任边界与数据处理

### 访达粘贴板输入

Finder 服务从 Finder 粘贴板读取 URL 对象，只接受同时满足本地（`file:`）和普通文件条件的第一个 URL；网页 URL 和目录会被拒绝。这缩小了服务输入面，但所选媒体仍然是 macOS 解码器和可选 FFmpeg 工具的不受信任输入。

请不要假定解析未知媒体文件没有风险。请保持 macOS 与 FFmpeg 更新，并避免在高价值环境中打开不受信任内容。

### 文件系统读取与写入

应用读取通过 Finder 选中的本地文件，或作为本地启动路径传入的文件。当前审阅源码中没有云上传或账号登录路径。

导出和图像保存需要用户可见的保存或确认操作：

- A/B 视频和音频导出使用 `NSSavePanel`，拒绝原始源路径和已存在目标路径。
- JPEG 转换和 JPEG 压缩总会创建新文件，拒绝源路径或被占用目标路径，先写入临时文件，再移入目标位置。
- 图像裁切保存默认创建带编号的同级文件并拒绝被占用目标路径。唯一替换源文件的路径是裁切保存对话框中明确选择的 **覆盖保存**，该路径使用 `replaceItemAt` 且不创建备份项。

因此，明确选择覆盖保存具有破坏性。需要保留源文件时，请使用 **另存为新文件**，并自行备份重要资产。

### 外部 FFmpeg 与 `ffprobe` 发现

应用不包含 FFmpeg 或 `ffprobe`。

- FFmpeg 与 `ffprobe` 首先查询用户管理的 `~/Library/Application Support/AI Video Cutty/bin`，随后仅为兼容旧安装查询 `~/Library/Application Support/Finder Media Preview/bin`，再查询标准系统位置和继承的 `PATH`。
- 使用第一个通过 `FileManager.isExecutableFile(atPath:)` 的候选程序。该检查只验证可执行性，不验证发布者身份、签名或包来源。
- 当 `ffprobe` 不可用或失败时，使用原生 AVFoundation 元数据回退。

请只从可信来源安装外部工具。可写入或受攻击者控制的 `PATH` 可能导致选择不同的可执行文件。若要受控部署，请使用用户管理目录并独立验证安装的 FFmpeg 来源。

### 打包的用户级安装器

仅当用户在应用中选择 **安装 FFmpeg…** 后，才会打开随附的 `安装 FFmpeg.command`。应用不会自动运行安装器。

该脚本：

- 仅在用户打开后下载外部 `ffmpeg-static b6.1.1` 二进制对；应用不包含任一二进制文件。
- 默认使用 `https://cdn.npmmirror.com/binaries/ffmpeg-static/b6.1.1`。只有默认请求发生连接或 HTTP 失败时才使用固定 GitHub 发布传输，摘要校验失败时绝不回退。
- 在解压前验证两个 gzip 资源的固定 SHA-256，并把所选来源与摘要记录在 `ai-video-cutty-ffmpeg-static-manifest.txt`；同时写入遗留的 `finder-media-preview-ffmpeg-static-manifest.txt` 以兼容旧安装。
- 仅安装到 `~/Library/Application Support/AI Video Cutty/bin`，不请求管理员权限，不使用 Homebrew 或 `sudo`，也不修改 shell 配置。
- 使用 GPL-3.0-or-later 外部运行时。[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 记录准确来源、许可证链接、发布资源名称和 SHA-256 值。

该安装器是供应链边界。对安装器、其 URL、回退规则、发布标签或校验和的修改都应视为安全敏感变更。

### 进程参数安全

FFmpeg 和 `ffprobe` 通过 Foundation `Process` 以可执行文件 URL 和参数数组启动。应用不会为媒体路径、裁切过滤器或导出目标构造 shell 命令字符串或调用 shell。FFmpeg 裁切操作包含 `-nostdin`；导出路径使用 FFmpeg 的 `-n` 标志，防止 FFmpeg 覆盖已有输出。

`ffprobe` 使用受限的五秒等待时间，并在解析前将捕获的 JSON 限制为 2 MiB。FFmpeg 错误输出在显示于错误提示前会被限制。这些限制是防御性控制，并不能替代模糊测试或完整的恶意媒体审查。

## 隐私与联网

核心预览和本地文件操作按离线可用设计。当前审阅应用源码不包含遥测、用户账号、分析或远程媒体处理。可选 FFmpeg 安装器是例外：它只会在用户操作后请求本文档说明的外部运行时。

自定义键盘绑定保存在本机用户默认设置中。媒体元数据可通过 AVFoundation、ImageIO 或可选 `ffprobe` 进程在本地读取。

## 安全敏感变更

更改以下任一内容前，请求针对性审查：

- Finder 服务输入解析或接受的 URL 类型。
- `NSSavePanel` 流程、目标冲突检查、临时文件处理或源文件替换。
- FFmpeg/`ffprobe` 发现路径、命令参数、进程生命周期或输出解析。
- 打包的外部运行时安装器、外部 URL、回退规则、签名或公证行为。
- 新增网络访问、特权操作、持久化或后台执行。

## 分发说明

本地构建脚本使用 ad-hoc 签名；它不提供 Developer ID 签名或 Apple 公证。分发前请审阅并验证确切产物，且不得将其表述为已公证或 Apple 批准的应用。
