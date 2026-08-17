# Contributing to Finder Media Preview

Thanks for considering a contribution. Finder Media Preview is a small macOS SwiftPM prototype, so focused, well-evidenced changes are more useful than broad rewrites.

## Before you start

- Read the [architecture overview](Docs/ARCHITECTURE.md) and the relevant source file before proposing a design change.
- Search existing discussions and issues in the hosting repository when they are available.
- Keep a change scoped to one user-visible problem or one well-defined maintenance need.
- Do not include media files, personal metadata, credentials, or generated build artifacts in a contribution.

## Local setup

Requirements:

- macOS 13 or later.
- Xcode Command Line Tools.
- A Swift toolchain compatible with the Swift 6 package manifest.

From the repository root:

```zsh
swift build
swift test
```

If your terminal is running under Rosetta on Apple Silicon, use the native test command:

```zsh
arch -arm64 swift test
```

`Scripts/build.sh` creates a local app bundle for manual testing. `Scripts/package_dmg.sh` packages an already-built app bundle and deliberately does not overwrite an existing release DMG. Do not submit either generated output unless maintainers explicitly request it.

## Contribution expectations

1. Describe the user problem, affected media type, and expected behavior.
2. Make the smallest durable change that addresses it.
3. Add or update tests for logic changes. Preserve coverage for validation, save decisions, media routing, and keyboard behavior when those areas are touched.
4. Run the relevant build and test commands locally, then state exactly what you ran and what remains unverified.
5. Update user-facing documentation when behavior, safety boundaries, requirements, or shortcuts change.

For UI, Finder Service, or media-decoder changes, distinguish code-level tests from manual macOS acceptance. A passing unit test does not prove Finder registration, Gatekeeper behavior, TCC permissions, external-display placement, or codec behavior on every macOS version.

## Change boundaries

- Preserve the local-first behavior. Do not add cloud uploads, analytics, network calls, background daemons, or third-party media binaries without a separately discussed design and security review.
- FFmpeg remains external and user-installed. Do not bundle a binary or make the installer run automatically.
- Preserve explicit user control over writes. New-file exports must not overwrite a source or occupied destination; source replacement must remain an explicit UI choice.
- Keep process launches shell-free. Pass executable URLs and argument arrays to `Process`; do not construct shell command strings from media paths or UI text.
- Maintain compatibility with macOS 13 unless a supported-platform decision is documented first.

## Pull request checklist

- [ ] The change has a concise problem statement and scope.
- [ ] Source, test, and documentation changes are limited to the stated purpose.
- [ ] Relevant tests pass locally.
- [ ] New or changed file writes have failure, collision, and cancellation behavior considered.
- [ ] New FFmpeg/ffprobe arguments are reviewed for source-path handling and no-shell execution.
- [ ] UI behavior has manual verification notes where unit tests cannot prove it.
- [ ] No private media, secrets, local paths, build directories, or release binaries are included.

## Reporting bugs and proposing features

Bug reports are most actionable when they include the macOS version, media type/container/codec (without sharing sensitive media), expected result, actual result, and a reproducible sequence. For crashes or decoder issues, include a minimal non-sensitive sample only when you are authorized to share it.

Use the private process in [SECURITY.md](SECURITY.md) for security-sensitive findings. Do not post a public exploit or a sensitive file path while a fix is being coordinated.

## License and conduct

By contributing, you agree that your contribution will be licensed under the repository's [MIT License](LICENSE). Please also follow the [Code of Conduct](CODE_OF_CONDUCT.md).
