# Security Policy

## Security status

Finder Media Preview is a community-built prototype. This document records the current security boundaries observed in the source; it is not a claim of a completed security audit or a guarantee of safety for untrusted media.

The latest `main` branch is the only currently supported source version. There are no supported prebuilt binary releases yet.

## Reporting a vulnerability

Use the repository's [GitHub Security Advisories private reporting form](https://github.com/AndrewBassZhang/finder-media-preview/security/advisories/new). Do not open a public issue, publish proof-of-concept media, or disclose exploitable file paths before the maintainer has acknowledged the report. The maintainer aims to acknowledge a complete report within seven days; remediation timing depends on severity and reproducibility.

Please include:

- A clear description of the impact and affected code path.
- Reproduction steps that avoid exposing private media or credentials.
- macOS version, hardware architecture, and FFmpeg/ffprobe installation details where relevant.
- A minimal sanitized test file or a description of how to recreate one, only if you are authorized to share it.

## Trust boundaries and data handling

### Finder pasteboard input

The Finder Service reads URL objects from the Finder pasteboard and accepts only the first URL that is both local (`file:`) and a regular file. It rejects web URLs and directories. This reduces the service input surface, but selected media remains untrusted input to macOS decoders and to optional FFmpeg tooling.

Do not assume that parsing an unknown media file is risk-free. Keep macOS and FFmpeg patched, and avoid opening untrusted content in a high-value environment.

### Filesystem reads and writes

The app reads the local file selected through Finder or passed as a local launch path. It does not contain a cloud upload or account-sign-in path in the reviewed source.

Exports and image saves require a user-facing save or confirmation action:

- A/B video and audio exports use an `NSSavePanel`, reject the original source path, and reject an existing destination.
- JPEG conversion and JPEG compression always create a new file, reject a source path or occupied destination, write to a temporary file, then move it into place.
- Image crop save defaults to a numbered sibling file and rejects an occupied destination. The only source-replacement path is the explicit **Overwrite Save** choice in the crop-save dialog. That path uses `replaceItemAt` without a backup item.

The explicit overwrite choice is therefore destructive. Use **Save as New File** when the source must be retained, and keep your own backup for important assets.

### External FFmpeg and ffprobe discovery

The app does not bundle FFmpeg or ffprobe.

- FFmpeg is considered only when an executable is found at `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `/usr/bin/ffmpeg`, or in the inherited `PATH`.
- The first candidate passing `FileManager.isExecutableFile(atPath:)` is used. This checks executability, not publisher identity, signature, or package provenance.
- FFprobe metadata enrichment uses `/opt/homebrew/bin/ffprobe`; native AVFoundation metadata is the fallback when it is unavailable or fails.

Install external tools only from sources you trust. A writable or attacker-controlled `PATH` can cause a different executable to be selected. For a controlled deployment, use a managed path and verify the installed FFmpeg provenance independently.

### Packaged Homebrew installer

The bundled `安装 FFmpeg.command` is opened only after a user chooses **Install FFmpeg…** in the app. The app does not run the installer automatically.

The script:

- Uses Homebrew's official installer URL when Homebrew is missing.
- Installs `ffmpeg` through Homebrew rather than downloading a bundled or third-party FFmpeg binary.
- Can use a USTC Homebrew bottles/API mirror only for the current installer invocation, if the user accepts that option; it does not write the mirror setting to shell configuration files.
- May cause Homebrew or macOS tools to request administrator authorization. Do not enter credentials unless you have reviewed the script and accept the Homebrew installation.

This installer is a supply-chain boundary. Treat updates to it, its URLs, mirror behavior, and package-manager assumptions as security-sensitive changes.

### Process argument safety

FFmpeg and ffprobe are launched with Foundation `Process` using an executable URL and an argument array. The app does not build a shell command string or invoke a shell for media paths, crop filters, or export destinations. FFmpeg trim operations include `-nostdin`; export paths use FFmpeg's `-n` flag to prevent FFmpeg from overwriting an existing output.

FFprobe runs with a bounded five-second wait and caps captured JSON at 2 MiB before parsing. FFmpeg error output is bounded before it is shown in an error alert. These limits are defensive controls, not substitutes for fuzzing or a complete hostile-media review.

## Privacy and networking

Core preview and local file operations are designed to work offline. The reviewed application sources do not include telemetry, user accounts, analytics, or remote media processing. The optional FFmpeg installer is the exception: it intentionally makes network requests to Homebrew and, only when selected, an optional mirror.

Custom keyboard bindings are persisted locally in user defaults. Media metadata may be read locally through AVFoundation, ImageIO, or the optional ffprobe process.

## Security-sensitive changes

Request a focused review before changing any of the following:

- Finder Service input parsing or the accepted URL types.
- `NSSavePanel` flow, destination collision checks, temporary-file handling, or source replacement.
- FFmpeg/ffprobe discovery paths, command arguments, process lifetime, or output parsing.
- The packaged Homebrew installer, external URLs, mirrors, signing, or notarization behavior.
- New network access, privileged operations, persistence, or background execution.

## Distribution note

The local build script applies ad-hoc signing. It does not provide Developer ID signing or Apple notarization. Review and verify the exact artifact before distribution; do not represent it as notarized or as an Apple-approved application.
