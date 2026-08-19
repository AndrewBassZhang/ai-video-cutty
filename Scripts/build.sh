#!/bin/zsh
emulate -LR zsh
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$task_root/build/AI Video Cutty.app"
icon_source="$task_root/Resources/AppIcon-1024.png"
icon_temp=''

cleanup() {
  if [[ -n "$icon_temp" && -d "$icon_temp" ]]; then
    rm -rf -- "$icon_temp"
  fi
}
trap cleanup EXIT HUP INT TERM

fail() { print -u2 -- "Error: $*"; exit 1; }

[[ -f "$icon_source" ]] || fail "app icon source not found: $icon_source"
command -v sips >/dev/null 2>&1 || fail 'sips is required to build the app icon.'
command -v iconutil >/dev/null 2>&1 || fail 'iconutil is required to build the app icon.'

cd "$task_root"
swift build -c release
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MediaPreview "$app/Contents/MacOS/MediaPreview"
cp Resources/Info.plist "$app/Contents/Info.plist"
install -m 644 Docs/使用说明.md "$app/Contents/Resources/使用说明.md"
install -m 755 Scripts/install_ffmpeg.sh "$app/Contents/Resources/install_ffmpeg.sh"
# The .command copy opens in Terminal when double-clicked in Finder.  Keep the
# .sh copy too, so the exact script is available for audit or terminal use.
install -m 755 Scripts/install_ffmpeg.sh "$app/Contents/Resources/安装 FFmpeg.command"

icon_temp="$(mktemp -d "${TMPDIR:-/tmp}/ai-video-cutty-icon.XXXXXX")" || fail 'could not create temporary iconset directory.'
iconset="$icon_temp/AppIcon.iconset"
mkdir -p "$iconset"

make_icon() {
  local pixels="$1"
  local filename="$2"
  sips -z "$pixels" "$pixels" "$icon_source" --out "$iconset/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
