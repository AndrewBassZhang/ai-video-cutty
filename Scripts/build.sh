#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
swift build -c release
app="$task_root/build/MediaPreview.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MediaPreview "$app/Contents/MacOS/MediaPreview"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Docs/使用说明.md "$app/Contents/Resources/使用说明.md"
if [[ -f Docs/使用说明.pdf ]]; then
  cp Docs/使用说明.pdf "$app/Contents/Resources/使用说明.pdf"
fi
install -m 755 Scripts/install_ffmpeg.sh "$app/Contents/Resources/install_ffmpeg.sh"
# The .command copy opens in Terminal when double-clicked in Finder.  Keep the
# .sh copy too, so the exact script is available for audit or terminal use.
install -m 755 Scripts/install_ffmpeg.sh "$app/Contents/Resources/安装 FFmpeg.command"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
