# Finder Media Preview

Finder Media Preview is a community-built, local-first macOS media preview utility. Select a local video, audio file, or image in Finder, open it through the app's Finder Service, and review it in a dedicated preview panel with transport, metadata, and focused export tools.

> This project is community-built and is not affiliated with, endorsed by, or sponsored by Apple or OpenAI.

## What it does

- Opens one selected local regular file from Finder, or a local file path passed at launch.
- Previews video, audio, and decodable images using macOS frameworks.
- Provides playback, looping, A/B markers, frame stepping, shuttle playback, timeline thumbnails, waveform display for audio, volume controls, and adjustable playback speed.
- Shows native media metadata and image metadata; richer media metadata is used when `ffprobe` is available.
- Lets you rotate or mirror the current video or image view. These display transforms can be baked into a newly exported file.
- Exports exact A/B video or audio trims through an optional external FFmpeg installation.
- Exports an audio stream without re-encoding when the chosen container supports it.
- Supports image crop/save, JPEG conversion, and JPEG compression workflows.
- Stores customizable preview shortcuts in the local user defaults database. `⌘S` remains reserved for the Finder entry point.

## Requirements

- macOS 13 Ventura or later.
- Xcode Command Line Tools and a Swift toolchain compatible with the package's Swift 6 manifest, for source builds.
- FFmpeg is optional for normal preview. It is required for A/B trim export and audio-stream export; `ffprobe` is optional for enhanced media metadata.

The app bundle does **not** contain FFmpeg or ffprobe. The optional installer keeps its externally downloaded pair in `~/Library/Application Support/Finder Media Preview/bin`; the app checks that user-managed directory first, then standard system locations and the launch environment's `PATH`.

## Build and test

Run these commands from the repository root.

```zsh
swift build -c release
swift test
```

If the command is being run from a Rosetta/x86 shell on Apple Silicon, run the tests natively instead:

```zsh
arch -arm64 swift test
```

To build the distributable app bundle used by this prototype:

```zsh
Scripts/build.sh
```

The script creates `build/MediaPreview.app`, copies the Chinese manual and optional FFmpeg installer script into the bundle, creates `AppIcon.icns`, and applies ad-hoc signing for local use. It recreates that build bundle on each run.

To create a drag-to-install disk image after the app bundle exists:

```zsh
Scripts/package_dmg.sh
```

This writes `dist/Finder-Media-Preview-macOS.dmg` and intentionally refuses to overwrite an existing DMG.

## Install

### From a local build

1. Run `Scripts/build.sh`.
2. Drag `build/MediaPreview.app` into `/Applications`.
3. Launch the app once, then select a local media file in Finder.

The prototype build uses ad-hoc signing; it is not Developer ID signed or notarized. If macOS blocks the first launch, Control-click the app, choose **Open**, then confirm **Open**. Review the source and the app bundle before bypassing macOS warnings.

### From a packaged DMG

1. Open `Finder-Media-Preview-macOS.dmg`.
2. Drag **Finder Media Preview.app** to **Applications**.
3. Control-click the app in **Applications**, choose **Open**, then confirm **Open** on the first launch. This prototype is ad-hoc signed and not notarized.
4. Reopen the app before using the Finder Service. The DMG also includes `安装说明.txt`, `使用说明.md`, third-party notices, and an optional FFmpeg installer.

## Finder Service and shortcut setup

After installing and launching the app once:

1. In Finder, select one local media file.
2. Invoke the app's media-preview entry from **Finder > Services**.
3. To assign or restore a Finder shortcut, open **System Settings > Keyboard > Keyboard Shortcuts > Services**, locate the installed media-preview service, and set its shortcut. The intended Finder shortcut is `⌘S`; test it with Finder as the frontmost app.

The application deliberately reserves `⌘S` in its own shortcut editor, so a configurable in-app action cannot shadow the Finder entry point. The Finder Service accepts only local regular files and uses the first eligible selected file; directories, web URLs, and additional selected files are not batch-opened.

## Keyboard shortcuts

These are the current default bindings. They can be changed in **Media Preview > Settings…** except for the dedicated Finder `⌘S` entry point.

| Action | Default |
| --- | --- |
| Play / pause | `Space` |
| Close preview | `⌘Q` |
| Jump backward / forward 5% | `⌘←` / `⌘→` |
| Shuttle reverse / pause / shuttle forward | `J` / `K` / `L` |
| Set A / B marker | `I` / `O` |
| Restart from the beginning | `R` |
| Toggle loop | `P` |
| Clear A/B markers | `X` |
| Mute / unmute | `M` |
| Reset video or image zoom | `0` |
| Paused video frame step | `←` / `→` |
| Playing video temporary shuttle | hold `←` / `→` |
| Volume down / up | `↓` / `↑` |

Plain arrow controls are reserved transport controls. For a playing video, releasing a held left or right arrow restores the previously selected forward playback speed.

## FFmpeg: optional, external, and explicit

FFmpeg is not needed to open or review media. It is required for precise A/B trim export and audio-stream export; `ffprobe` adds richer media metadata. If either is unavailable, the app shows an install option; it does not silently install anything.

The packaged installer runs only after you explicitly open it or choose **Install FFmpeg…**. It downloads the external `ffmpeg-static b6.1.1` runtime to `~/Library/Application Support/Finder Media Preview/bin`, with no administrator privileges and no bundled binary. Its default transport is `https://cdn.npmmirror.com/binaries/ffmpeg-static/b6.1.1`; only a connection or HTTP failure falls back to the fixed upstream release transport at `https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1`. It verifies the pinned SHA-256 of both downloaded gzip assets before installation; a digest mismatch stops rather than falling back.

The external runtime is GPL-3.0-or-later. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the exact source, license link, asset names, and digests. You may instead install FFmpeg yourself. Restart the app after installation so its executable check is refreshed.

## Privacy and offline behavior

Core preview, editing, metadata fallback, and file-save workflows run locally. The inspected application code contains no account sign-in, telemetry client, cloud upload, or network media processing path. The only networked workflow included in this prototype is the optional, user-initiated external-runtime download described above.

The Finder Service receives the selected file URL from the Finder pasteboard. Custom shortcut bindings are stored locally in user defaults. Media files are read from their local paths and are written only through an export or save action you choose. See [SECURITY.md](SECURITY.md) for the exact write and external-tool boundaries.

## Limitations

- Media playback and decoding support depend on the codecs exposed by the installed macOS version; unsupported formats may not open.
- The app opens one eligible Finder selection at a time; it is not a batch browser or library manager.
- Exact A/B trim export re-encodes video and audio. It is not a byte-for-byte source copy.
- Audio-stream export preserves packets where possible, so A/B boundaries are packet-aligned rather than sample-accurate and a chosen destination container may reject the source codec.
- Image crop save offers an explicit **Overwrite Save** choice. That action replaces the source without creating a backup; use **Save as New File** if you need to preserve it.
- This prototype is ad-hoc signed and not notarized.

## Roadmap

Potential community priorities, not release commitments:

- Developer ID signing and notarization for distributed builds.
- A documented codec/support matrix and clearer incompatibility diagnostics.
- Accessibility and real Finder-Service end-to-end test coverage.
- A formal release process, versioned release notes, and a vulnerability-reporting contact.

## Documentation

- [Architecture](Docs/ARCHITECTURE.md)
- [DMG installation guide](Docs/安装说明.txt)
- [Chinese user manual](Docs/使用说明.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)

## License

Finder Media Preview is available under the [MIT License](LICENSE).

## 中文简介

Finder Media Preview 是一个本地运行的 macOS 媒体预览原型：可从 Finder 的服务入口打开一条本地视频、音频或图片，并提供播放、A/B 循环、元数据、旋转/镜像、裁切和另存等操作。普通预览不需要 FFmpeg；精确 A/B 导出和原码流音频导出需要用户自行安装的 FFmpeg，应用不会静默下载或安装它。当前版本为社区构建，与 Apple 和 OpenAI 没有隶属、背书或合作关系。
