# Architecture

## Purpose and scope

Finder Media Preview is a single-target macOS SwiftPM executable. Its current architecture favors a small, local AppKit application over a service or daemon: Finder supplies one selected local file, the app presents a preview panel, and optional export flows create user-selected local output files.

This document maps the present source tree. It describes implementation boundaries, not a runtime security certification or a promise of API stability.

## System view

```text
Finder selection or local launch argument
        |
        v
AppDelegate / LaunchInput / ServiceInput
        |  validates a local regular file
        v
MediaRoute (UniformTypeIdentifiers + ImageIO preflight)
        |
        +-------------------+-------------------+
        |                   |                   |
        v                   v                   v
   video / audio          image            unsupported
        |                   |                   |
        v                   v                   v
 AVFoundation + AVKit    ImageIO        graceful termination
        |                   |
        +---------+---------+
                  v
       PreviewController + AppKit views
                  |
        +---------+----------+
        |                    |
        v                    v
  local preview/UI      explicit export/save
                              |
                 +------------+-------------+
                 |                          |
                 v                          v
       ImageIO temporary write      external FFmpeg Process
```

## Source layout

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Declares a macOS 13 SwiftPM executable target and its test target. |
| `Sources/MediaPreview/App.swift` | Application lifecycle, Finder Service entry, media routing, panel and controller composition, playback state, shortcut storage, image-save behavior, FFmpeg plans/processes, and app-level export orchestration. |
| `Sources/MediaPreview/TimelineView.swift` | Custom AppKit timeline, waveform extraction/display, player/image zoom surfaces, volume control, A/B marker rendering, and related view math. |
| `Sources/MediaPreview/CropEditor.swift` | Crop presets, transformed-canvas geometry, display transforms, interactive crop view, and the crop editor sheet. |
| `Sources/MediaPreview/Metadata.swift` | Image metadata parsing, native AVFoundation media metadata fallback, optional ffprobe enrichment, and display formatting. |
| `Tests/MediaPreviewTests/` | XCTest coverage for routing, layout, export planning, transforms, metadata parsing, keyboard behavior, and save-safety decisions. |
| `Scripts/build.sh` | Builds the release executable, assembles the local app bundle, embeds the manuals/installer, and applies ad-hoc signing. |
| `Scripts/install_ffmpeg.sh` | Explicit, Terminal-visible Homebrew route for installing external FFmpeg. |
| `Scripts/package_dmg.sh` | Packages an existing app bundle into a non-overwriting drag-install DMG. |

## AppKit composition

### Entry and Finder integration

`AppDelegate` is the AppKit entry point. It supports two local inputs:

- `LaunchInput` normalizes a filesystem path or a `file:` launch argument and rejects non-file URLs.
- `showMediaPreview(_:userData:error:)` receives the Finder Service pasteboard. `ServiceInput` reads URL objects, then selects the first local URL that resolves to a regular file.

`presentPreview(for:)` routes the file, constructs a `PreviewController`, and places a `PreviewPanel`. The panel's visible frame prefers the first detected screen, falls back to `NSScreen.main`, and finally uses a fixed fallback frame. A local key-event monitor routes preview keys only while the preview panel is active, preserving text entry in sheets and settings UI.

### Preview controller and custom views

`PreviewController` owns the selected URL, media kind, `AVPlayer`, view hierarchy, playback state, A/B markers, display transforms, save/export UI, and teardown. It composes:

- `ZoomablePlayerSurface`, which wraps `AVPlayerView` for video/audio presentation, magnification, pan, and display transforms.
- `ZoomableImageSurface`, which presents an `NSImageView` with analogous image zoom/pan/transforms.
- `TimelineView`, which shows playhead, A/B markers, video thumbnails, and audio waveform data.
- `VerticalVolumeControl`, transport buttons, speed controls, export state, and top-level manual/shortcut actions.
- `ShortcutSettingsWindowController`, backed by `ShortcutStore` in local user defaults.

The controller treats plain arrow keys as dedicated transport/volume controls. Configurable bindings remain separate, and `⌘S` is rejected from the in-app shortcut store so it can remain the Finder entry shortcut.

## Media framework boundaries

### Uniform Type Identifiers and ImageIO

`MediaRoute` uses `UniformTypeIdentifiers` to classify local files as image, audio, video, or unsupported. Image classification has an ImageIO decode preflight, which lets a decodable image be previewed even when its file type is not otherwise classified as an image.

`ImagePreview` uses `CGImageSource` to decode the first image and obtain metadata. `ImageMetadata` extracts display-facing values such as file format, dimensions, color information, EXIF/TIFF camera details, and exposure fields. `ImageRasterExporter` applies the current transform/crop plan and writes image output through a temporary file.

### AVFoundation and AVKit

Video and audio playback are built on `AVPlayer`, `AVPlayerItem`, `AVURLAsset`, and `AVPlayerView`. The controller uses AVFoundation for duration, track discovery, exact seeks, A/B loop coordination, player-item end events, thumbnail generation, crop-preview generation, and native metadata fallback.

`TimelineView` uses AVFoundation decoding to extract audio samples for waveform display. It is intentionally a UI aid, not a source editor or a universal codec implementation.

`VideoDisplayTransform` represents user-requested quarter turns and horizontal mirroring. Crop coordinates are evaluated on the transformed display canvas so the crop editor, preview, and FFmpeg filter plan share the same order: source orientation normalization, user rotation/mirror, then crop.

### Metadata fallback and optional ffprobe

`NativeMediaMetadata` uses AVFoundation so basic media information remains available without Homebrew or ffprobe. `FFprobe` is an optional enrichment path. It starts `/opt/homebrew/bin/ffprobe` through `Process`, collects JSON to a temporary file, enforces a five-second deadline and a 2 MiB output limit, then falls back to native metadata on failure.

## Export and save flows

### Video and audio trimming

`ABTrimExportPlan` validates an ordered A/B time range. `FFmpegTrimExportPlan` translates it into a deterministic FFmpeg argument array:

- Video trim exports use H.264 (CRF 18) with AAC audio and can include the current rotation/mirror/crop filter chain.
- Exact audio trim exports encode to AAC, MP3, or WAV according to the chosen output type.
- Audio-stream export uses `FFmpegAudioExportPlan` with stream copy when the destination container supports the source audio. A/B stream-copy boundaries are packet-aligned.

`FFmpegLocator` searches standard executable locations and the inherited `PATH`, while `FFmpegAvailability` verifies the candidate with `-version`. `FFmpegTrimProcess` starts the selected executable via Foundation `Process` with an argument array, reads `-progress pipe:1`, caps retained standard-error text, and reports completion asynchronously to the main actor. It does not use a shell command string.

`NSSavePanel` supplies output paths. Before launching FFmpeg, the controller rejects the source path and any already-existing destination. FFmpeg exports use `-n`, preventing FFmpeg from replacing an existing file.

### Image saves

Image crop save enters `CropEditorSheetController`, then presents an explicit decision:

- **Save as New File** derives a numbered sibling path and refuses source-path or occupied-destination writes.
- **Overwrite Save** is the only source replacement path. It is a deliberate confirmation action and uses `FileManager.replaceItemAt` without a backup item.

JPEG conversion and compression never overwrite the source. They render locally, write a temporary file atomically, then move it to a destination that has passed collision checks.

## State and lifecycle

The app keeps one `PreviewPanel` and one `PreviewController` per running process. When a panel already exists, `presentPreview` repositions and foregrounds that panel rather than constructing another one. Closing the panel removes the key monitor, cancels outstanding work, tears down player observers and image-generation requests, terminates a running FFmpeg process, and exits the app.

State that persists across launches is intentionally narrow: only custom keyboard bindings are stored in user defaults. The app does not maintain a media catalog, watch folder, sync queue, login session, or background service.

## Packaging and distribution

`Scripts/build.sh` compiles the SwiftPM release target, assembles `build/MediaPreview.app`, copies the Chinese manual and FFmpeg installer into the bundle's resources, and applies ad-hoc signing. `Scripts/package_dmg.sh` stages the app with an Applications symlink and manual, verifies the app signature, creates a compressed read-only DMG, and refuses to replace an existing DMG.

This is a local packaging route, not a notarized release pipeline. Developer ID signing, notarization, and public-release provenance remain future work.

## Extension guidance

Keep new functionality within these boundaries unless there is an approved design change:

- Preserve a user-triggered, local-file entry model.
- Keep FFmpeg external and process invocation shell-free.
- Preserve explicit save choices, source/destination collision checks, and temporary-write cleanup.
- Add pure logic tests when possible; separate manual Finder/macOS validation from XCTest evidence.
- Document any change to shortcut behavior, media-write semantics, external process discovery, or network behavior in `README.md` and `SECURITY.md`.
