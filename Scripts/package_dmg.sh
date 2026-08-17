#!/bin/zsh
# Build a drag-to-install release disk image from an already-built app bundle.
# This script intentionally never overwrites an existing release image.

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly PROJECT_DIR=${SCRIPT_DIR:h}
readonly APP_SOURCE=${PROJECT_DIR}/build/MediaPreview.app
readonly MANUAL_SOURCE=${PROJECT_DIR}/Docs/使用说明.md
readonly PDF_MANUAL_SOURCE=${PROJECT_DIR}/Docs/使用说明.pdf
readonly DIST_DIR=${PROJECT_DIR}/dist
readonly DMG_NAME=Finder-Media-Preview-macOS.dmg
readonly OUTPUT_DMG=${DIST_DIR}/${DMG_NAME}
readonly VOLUME_NAME='Finder Media Preview'
readonly TEMP_BASE=${TMPDIR:-/tmp}

stage_dir=''
mount_dir=''
image_attached=0

cleanup() {
  local exit_status=$?

  if (( image_attached )); then
    hdiutil detach "$mount_dir" -quiet || \
      print -u2 -- "Warning: could not detach temporary image at: $mount_dir"
  fi
  if [[ "$stage_dir" == "${TEMP_BASE%/}/finder-media-preview."* && -d "$stage_dir" ]]; then
    rm -rf -- "$stage_dir"
  fi
  exit "$exit_status"
}

trap cleanup EXIT HUP INT TERM

fail() {
  print -u2 -- "Error: $*"
  exit 1
}

[[ -d "$APP_SOURCE" ]] || fail "built app not found: $APP_SOURCE"
[[ -f "$MANUAL_SOURCE" ]] || fail "Markdown manual not found: $MANUAL_SOURCE"
command -v hdiutil >/dev/null 2>&1 || fail 'hdiutil is required to create a DMG.'
command -v codesign >/dev/null 2>&1 || fail 'codesign is required to verify the app.'

if [[ -e "$OUTPUT_DMG" ]]; then
  fail "refusing to overwrite existing release image: $OUTPUT_DMG"
fi

mkdir -p -- "$DIST_DIR"
[[ -w "$DIST_DIR" ]] || fail "dist directory is not writable: $DIST_DIR"

print -- "Verifying source app signature…"
codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"

stage_dir=$(mktemp -d "${TEMP_BASE%/}/finder-media-preview.XXXXXX") || \
  fail 'could not create a temporary staging directory.'
readonly STAGE_ROOT=${stage_dir}/volume
mount_dir=${stage_dir}/mount
mkdir -p -- "$STAGE_ROOT" "$mount_dir"

print -- "Staging release contents…"
ditto "$APP_SOURCE" "$STAGE_ROOT/Finder Media Preview.app"
ln -s /Applications "$STAGE_ROOT/Applications"
ditto "$MANUAL_SOURCE" "$STAGE_ROOT/使用说明.md"
if [[ -f "$PDF_MANUAL_SOURCE" ]]; then
  ditto "$PDF_MANUAL_SOURCE" "$STAGE_ROOT/使用说明.pdf"
  print -- 'Included Docs/使用说明.pdf.'
else
  print -- 'Docs/使用说明.pdf not present; included Markdown manual only.'
fi

print -- "Verifying staged app signature…"
codesign --verify --deep --strict --verbose=2 "$STAGE_ROOT/Finder Media Preview.app"

# A standard drag-install layout is deliberately used. Finder window/view settings
# are user-visible mutable state, so this script does not drive Finder via AppleScript.
print -- "Creating compressed read-only DMG…"
hdiutil create \
  -format UDZO \
  -imagekey zlib-level=9 \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_ROOT" \
  "$OUTPUT_DMG"

print -- "Verifying DMG image…"
hdiutil verify "$OUTPUT_DMG"

print -- "Mounting DMG privately to verify packaged app signature…"
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$mount_dir" "$OUTPUT_DMG" >/dev/null
image_attached=1
codesign --verify --deep --strict --verbose=2 "$mount_dir/Finder Media Preview.app"
hdiutil detach "$mount_dir" -quiet
image_attached=0

print -- "Created and verified: $OUTPUT_DMG"
