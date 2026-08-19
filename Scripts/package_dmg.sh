#!/bin/zsh
# Build a drag-to-install release disk image from an already-built app bundle.
# This script intentionally never overwrites an existing release image.

emulate -LR zsh
set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly PROJECT_DIR=${SCRIPT_DIR:h}
readonly APP_NAME='AI Video Cutty'
readonly APP_SOURCE=${PROJECT_DIR}/build/${APP_NAME}.app
readonly INSTALLER_SOURCE=${PROJECT_DIR}/Scripts/install_ffmpeg.sh
readonly INSTALLER_NAME='安装 FFmpeg（无需 Homebrew）.command'
readonly INSTALL_GUIDE_SOURCE=${PROJECT_DIR}/Docs/安装说明.txt
readonly MANUAL_SOURCE=${PROJECT_DIR}/Docs/使用说明.md
readonly NOTICES_SOURCE=${PROJECT_DIR}/THIRD_PARTY_NOTICES.md
readonly DIST_DIR=${PROJECT_DIR}/dist
readonly DMG_NAME=AI-Video-Cutty-macOS.dmg
readonly OUTPUT_DMG=${DIST_DIR}/${DMG_NAME}
readonly VOLUME_NAME=${APP_NAME}
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
  if [[ "$stage_dir" == "${TEMP_BASE%/}/ai-video-cutty."* && -d "$stage_dir" ]]; then
    rm -rf -- "$stage_dir"
  fi
  exit "$exit_status"
}

trap cleanup EXIT HUP INT TERM

fail() {
  print -u2 -- "Error: $*"
  exit 1
}

verify_release_contents() {
  local root="$1"
  local application_link=''

  [[ -d "$root/$APP_NAME.app" ]] || fail "required app is missing: $root/$APP_NAME.app"
  [[ -L "$root/Applications" ]] || fail "required Applications link is missing: $root/Applications"
  application_link="$(readlink "$root/Applications")" || fail "could not read Applications link: $root/Applications"
  [[ "$application_link" == '/Applications' ]] || fail "Applications link must target /Applications, got: $application_link"
  [[ -f "$root/$INSTALLER_NAME" ]] || fail "required installer is missing: $root/$INSTALLER_NAME"
  [[ -x "$root/$INSTALLER_NAME" ]] || fail "installer is not executable: $root/$INSTALLER_NAME"
  [[ -f "$root/安装说明.txt" ]] || fail "required install guide is missing: $root/安装说明.txt"
  [[ -f "$root/使用说明.md" ]] || fail "required manual is missing: $root/使用说明.md"
  [[ -f "$root/THIRD_PARTY_NOTICES.md" ]] || fail "required third-party notice is missing: $root/THIRD_PARTY_NOTICES.md"
  [[ -f "$root/$APP_NAME.app/Contents/Resources/AppIcon.icns" ]] || \
    fail "app icon is missing: $root/$APP_NAME.app/Contents/Resources/AppIcon.icns"
  [[ ! -e "$root/使用说明.pdf" ]] || fail "PDF manuals must not be packaged: $root/使用说明.pdf"
}

[[ -d "$APP_SOURCE" ]] || fail "built app not found: $APP_SOURCE"
[[ -x "$INSTALLER_SOURCE" ]] || fail "installer script is missing or not executable: $INSTALLER_SOURCE"
[[ -f "$INSTALL_GUIDE_SOURCE" ]] || fail "install guide not found: $INSTALL_GUIDE_SOURCE"
[[ -f "$MANUAL_SOURCE" ]] || fail "Markdown manual not found: $MANUAL_SOURCE"
[[ -f "$NOTICES_SOURCE" ]] || fail "third-party notice not found: $NOTICES_SOURCE"
[[ -f "$APP_SOURCE/Contents/Resources/AppIcon.icns" ]] || \
  fail "built app icon not found: $APP_SOURCE/Contents/Resources/AppIcon.icns"
command -v hdiutil >/dev/null 2>&1 || fail 'hdiutil is required to create a DMG.'
command -v codesign >/dev/null 2>&1 || fail 'codesign is required to verify the app.'

if [[ -e "$OUTPUT_DMG" ]]; then
  fail "refusing to overwrite existing release image: $OUTPUT_DMG"
fi

mkdir -p -- "$DIST_DIR"
[[ -w "$DIST_DIR" ]] || fail "dist directory is not writable: $DIST_DIR"

print -- "Verifying source app signature…"
codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"

stage_dir=$(mktemp -d "${TEMP_BASE%/}/ai-video-cutty.XXXXXX") || \
  fail 'could not create a temporary staging directory.'
readonly STAGE_ROOT=${stage_dir}/volume
mount_dir=${stage_dir}/mount
mkdir -p -- "$STAGE_ROOT" "$mount_dir"

print -- "Staging release contents…"
ditto "$APP_SOURCE" "$STAGE_ROOT/$APP_NAME.app"
ln -s /Applications "$STAGE_ROOT/Applications"
install -m 755 "$INSTALLER_SOURCE" "$STAGE_ROOT/$INSTALLER_NAME"
ditto "$INSTALL_GUIDE_SOURCE" "$STAGE_ROOT/安装说明.txt"
ditto "$MANUAL_SOURCE" "$STAGE_ROOT/使用说明.md"
ditto "$NOTICES_SOURCE" "$STAGE_ROOT/THIRD_PARTY_NOTICES.md"
verify_release_contents "$STAGE_ROOT"

print -- "Verifying staged app signature…"
codesign --verify --deep --strict --verbose=2 "$STAGE_ROOT/$APP_NAME.app"

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
verify_release_contents "$mount_dir"
codesign --verify --deep --strict --verbose=2 "$mount_dir/$APP_NAME.app"
hdiutil detach "$mount_dir" -quiet
image_attached=0

print -- "Created and verified: $OUTPUT_DMG"
