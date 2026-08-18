# Third-Party Notices

## Optional FFmpeg and FFprobe runtime

Finder Media Preview does not bundle FFmpeg or ffprobe. Only when the user explicitly runs the optional installer does it download the following external runtime pair into `~/Library/Application Support/Finder Media Preview/bin`.

- Project and tagged release: [`eugeneware/ffmpeg-static` `b6.1.1`](https://github.com/eugeneware/ffmpeg-static/releases/tag/b6.1.1)
- Upstream release transport: `https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1`
- Default installer transport: `https://cdn.npmmirror.com/binaries/ffmpeg-static/b6.1.1`
- License: [GPL-3.0-or-later](https://github.com/eugeneware/ffmpeg-static/blob/b6.1.1/LICENSE)

The default transport is used first. The installer may use the fixed upstream release transport only after a connection or HTTP failure; it never falls back after a digest mismatch. It verifies the following SHA-256 digests of the compressed release assets before decompression:

| macOS architecture | Asset | SHA-256 (gzip asset) |
| --- | --- | --- |
| arm64 | `ffmpeg-darwin-arm64.gz` | `8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa` |
| arm64 | `ffprobe-darwin-arm64.gz` | `d986a8ec7b030899fe66a8a288ed809a3543338705a3ce178cfb85869c5d80be` |
| x64 | `ffmpeg-darwin-x64.gz` | `929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106` |
| x64 | `ffprobe-darwin-x64.gz` | `d4da574d6e2e197bd259b47d69cf262df9e312af24ad960444f6d806d3d4c186` |

The installer records the selected source and validated digests in `finder-media-preview-ffmpeg-static-manifest.txt` beside the installed executables. This project is MIT-licensed; the optional external runtime remains separately licensed under GPL-3.0-or-later.
