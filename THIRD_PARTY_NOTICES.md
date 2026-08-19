# 第三方声明

## 可选的 FFmpeg 与 FFprobe 运行时

AI Video Cutty 不包含 FFmpeg 或 `ffprobe`。只有在用户主动运行可选安装器时，才会将下列外部运行时对下载到 `~/Library/Application Support/AI Video Cutty/bin`。

- 项目与带标签发布版：[`eugeneware/ffmpeg-static` `b6.1.1`](https://github.com/eugeneware/ffmpeg-static/releases/tag/b6.1.1)
- 上游发布传输地址：`https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1`
- 安装器默认传输地址：`https://cdn.npmmirror.com/binaries/ffmpeg-static/b6.1.1`
- 许可证：[GPL-3.0-or-later](https://github.com/eugeneware/ffmpeg-static/blob/b6.1.1/LICENSE)

安装器会先使用默认传输地址。仅在连接或 HTTP 请求失败后，才可使用固定上游发布传输地址；摘要不匹配后绝不回退。它会在解压前验证下列压缩发布资源的 SHA-256 摘要：

| macOS 架构 | 资源 | SHA-256（gzip 资源） |
| --- | --- | --- |
| arm64 | `ffmpeg-darwin-arm64.gz` | `8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa` |
| arm64 | `ffprobe-darwin-arm64.gz` | `d986a8ec7b030899fe66a8a288ed809a3543338705a3ce178cfb85869c5d80be` |
| x64 | `ffmpeg-darwin-x64.gz` | `929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106` |
| x64 | `ffprobe-darwin-x64.gz` | `d4da574d6e2e197bd259b47d69cf262df9e312af24ad960444f6d806d3d4c186` |

安装器会在已安装的可执行文件旁写入所选来源和已验证摘要，主清单为 `ai-video-cutty-ffmpeg-static-manifest.txt`，并为兼容旧安装同时写入 `finder-media-preview-ffmpeg-static-manifest.txt`。本项目采用 MIT License；可选外部运行时仍单独采用 GPL-3.0-or-later 许可证。
