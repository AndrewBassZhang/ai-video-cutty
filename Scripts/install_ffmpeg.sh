#!/bin/zsh
# Optional, per-user FFmpeg/ffprobe installer for AI Video Cutty.
# It intentionally has no Homebrew, npm, sudo, Xcode CLT, or remote-script path.

emulate -LR zsh
set -euo pipefail

readonly VERSION='b6.1.1'
readonly DOMESTIC_BASE='https://cdn.npmmirror.com/binaries/ffmpeg-static/b6.1.1'
readonly UPSTREAM_BASE='https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1'
readonly MANIFEST_NAME='ai-video-cutty-ffmpeg-static-manifest.txt'
readonly LEGACY_MANIFEST_NAME='finder-media-preview-ffmpeg-static-manifest.txt'

source_mode='domestic'
dry_run=0
stage_dir=''

log() { print -- "[AI Video Cutty] $*"; }
warn() { print -u2 -- "[AI Video Cutty] 注意：$*"; }
fail() { print -u2 -- "[AI Video Cutty] 失败：$*"; exit 1; }

usage() {
  cat <<'EOF'
用法：安装\ FFmpeg.command [--domestic | --upstream] [--dry-run]

  --domestic  默认。先用 npmmirror 国内源；只有连接或 HTTP 失败时才回退到固定 GitHub 上游发布页。
  --upstream  只用固定 GitHub 上游发布页。
  --dry-run   只显示会执行的步骤；不联网、不创建目录、不安装文件。

安装位置：${AI_VIDEO_CUTTY_BIN_DIR:-${FINDER_MEDIA_PREVIEW_BIN_DIR:-$HOME/Library/Application Support/AI Video Cutty/bin}}
EOF
}

cleanup() {
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
    rm -rf -- "$stage_dir"
  fi
}
trap cleanup EXIT HUP INT TERM

while (( $# )); do
  case "$1" in
    --domestic) source_mode='domestic' ;;
    --upstream) source_mode='upstream' ;;
    --dry-run) dry_run=1 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "不认识的参数：$1（可用 --help 查看用法）" ;;
  esac
  shift
done

[[ "$(uname -s)" == 'Darwin' ]] || fail '此安装脚本仅适用于 macOS。'

case "$(uname -m)" in
  arm64) asset_arch='arm64' ;;
  x86_64)
    # Rosetta reports x86_64 from uname even on Apple Silicon.  Trust only an
    # explicit translated-process or ARM-hardware signal; native Intel stays x64.
    if [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" == '1' ]] || \
       [[ "$(sysctl -in hw.optional.arm64 2>/dev/null || true)" == '1' ]]; then
      asset_arch='arm64'
    else
      asset_arch='x64'
    fi
    ;;
  *) fail "不支持的 macOS 架构：$(uname -m)（仅支持 arm64 与 x86_64）" ;;
esac

home_directory="${HOME:-}"
[[ -n "$home_directory" ]] || fail '没有可用的 HOME，无法确定用户级安装目录。'
install_dir="${AI_VIDEO_CUTTY_BIN_DIR:-${FINDER_MEDIA_PREVIEW_BIN_DIR:-$home_directory/Library/Application Support/AI Video Cutty/bin}}"
[[ -n "$install_dir" ]] || fail '安装目录为空。'

readonly FFMPEG_ASSET="ffmpeg-darwin-${asset_arch}.gz"
readonly FFPROBE_ASSET="ffprobe-darwin-${asset_arch}.gz"

case "$asset_arch" in
  arm64)
    readonly FFMPEG_SHA256='8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa'
    readonly FFPROBE_SHA256='d986a8ec7b030899fe66a8a288ed809a3543338705a3ce178cfb85869c5d80be'
    ;;
  x64)
    readonly FFMPEG_SHA256='929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106'
    readonly FFPROBE_SHA256='d4da574d6e2e197bd259b47d69cf262df9e312af24ad960444f6d806d3d4c186'
    ;;
esac

download_archive() {
  local base="$1"
  local asset="$2"
  local destination="$3"
  curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --retry 1 --retry-delay 1 \
    --silent --show-error --output "$destination" "${base}/${asset}"
}

verify_gzip_digest() {
  local archive="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')" || fail "无法计算 ${label} gzip 的 SHA-256。"
  [[ "$actual" == "$expected" ]] || fail "${label} gzip SHA-256 不匹配（期望 ${expected}，实际 ${actual}）。已取消；校验失败绝不回退到其他源。"
  print -- "$actual"
}

typeset -A downloaded_url
typeset -A downloaded_digest

fetch_and_verify() {
  local label="$1"
  local asset="$2"
  local expected="$3"
  local archive="$stage_dir/${label}.gz"
  local base=''

  if [[ "$source_mode" == 'upstream' ]]; then
    base="$UPSTREAM_BASE"
    log "下载 ${asset}（固定上游发布页）…"
    download_archive "$base" "$asset" "$archive" || fail "无法从固定上游发布页下载 ${asset}。"
  else
    base="$DOMESTIC_BASE"
    log "下载 ${asset}（默认国内源）…"
    if ! download_archive "$base" "$asset" "$archive"; then
      # A fallback is allowed only for a transport/HTTP failure.  It is
      # intentionally outside verify_gzip_digest, so a digest mismatch stops.
      rm -f -- "$archive"
      warn "国内源连接或 HTTP 请求失败；仅本次回退到固定上游发布页。"
      base="$UPSTREAM_BASE"
      download_archive "$base" "$asset" "$archive" || fail "国内源与固定上游发布页都无法下载 ${asset}。"
    fi
  fi

  downloaded_url[$label]="${base}/${asset}"
  downloaded_digest[$label]="$(verify_gzip_digest "$archive" "$expected" "$label")"
  log "${label} gzip SHA-256 已验证。"
}

stage_executable() {
  local label="$1"
  local archive="$stage_dir/${label}.gz"
  local executable="$stage_dir/${label}"
  gzip -dc -- "$archive" > "$executable" || fail "无法解压 ${label}。"
  chmod 755 "$executable"
  "$executable" -version >/dev/null 2>&1 || fail "${label} 不能通过 -version 自检。"
  log "${label} 可执行文件已通过 -version 自检。"
}

write_manifest_file() {
  local manifest_name="$1"
  local product_name="$2"
  cat > "$stage_dir/$manifest_name" <<EOF
${product_name} FFmpeg-static provenance
version=${VERSION}
architecture=${asset_arch}
installed_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
ffmpeg_asset=${FFMPEG_ASSET}
ffmpeg_source=${downloaded_url[ffmpeg]}
ffmpeg_gzip_sha256_expected=${FFMPEG_SHA256}
ffmpeg_gzip_sha256_actual=${downloaded_digest[ffmpeg]}
ffprobe_asset=${FFPROBE_ASSET}
ffprobe_source=${downloaded_url[ffprobe]}
ffprobe_gzip_sha256_expected=${FFPROBE_SHA256}
ffprobe_gzip_sha256_actual=${downloaded_digest[ffprobe]}
license=https://github.com/eugeneware/ffmpeg-static/blob/b6.1.1/LICENSE
EOF
}

write_manifest() {
  write_manifest_file "$MANIFEST_NAME" 'AI Video Cutty'
  # Keep the historical filename and header for local tooling that previously
  # consumed its provenance record. Both manifests describe the same verified pair.
  write_manifest_file "$LEGACY_MANIFEST_NAME" 'Finder Media Preview'
}

replace_staged_files() {
  local item
  for item in ffmpeg ffprobe "$MANIFEST_NAME" "$LEGACY_MANIFEST_NAME"; do
    [[ ! -d "$install_dir/$item" ]] || fail "目标路径是目录，拒绝替换：$install_dir/$item"
  done
  for item in ffmpeg ffprobe "$MANIFEST_NAME" "$LEGACY_MANIFEST_NAME"; do
    mv -f -- "$stage_dir/$item" "$install_dir/$item" || fail "无法替换 $install_dir/$item。旧文件可能仍可用；请检查目录权限后重试。"
  done
}

if (( dry_run )); then
  log '演练模式：不联网、不创建目录、不安装文件。'
  log "架构：${asset_arch}；版本：${VERSION}"
  if [[ "$source_mode" == 'upstream' ]]; then
    log "将从固定上游下载：${UPSTREAM_BASE}/{${FFMPEG_ASSET},${FFPROBE_ASSET}}"
  else
    log "将优先从国内源下载：${DOMESTIC_BASE}/{${FFMPEG_ASSET},${FFPROBE_ASSET}}"
    log "只有连接或 HTTP 失败时才回退到：${UPSTREAM_BASE}"
  fi
  log "将验证两个 gzip SHA-256、解压并运行 -version，然后安装到：${install_dir}"
  log "不会使用 Homebrew、npm、sudo、Xcode Command Line Tools 或远程脚本。"
  exit 0
fi

mkdir -p -- "$install_dir" || fail "无法创建用户级安装目录：$install_dir"
[[ -w "$install_dir" ]] || fail "安装目录不可写：$install_dir"
stage_dir="$(mktemp -d "${install_dir}/.ai-video-cutty-ffmpeg-stage.XXXXXX")" || fail '无法创建安装暂存目录。'

log "安装 FFmpeg-static ${VERSION}（${asset_arch}）到用户目录；不会请求管理员密码。"
fetch_and_verify ffmpeg "$FFMPEG_ASSET" "$FFMPEG_SHA256"
fetch_and_verify ffprobe "$FFPROBE_ASSET" "$FFPROBE_SHA256"
stage_executable ffmpeg
stage_executable ffprobe
write_manifest
replace_staged_files

"$install_dir/ffmpeg" -version >/dev/null 2>&1 || fail '安装后的 ffmpeg 未通过 -version 自检。'
"$install_dir/ffprobe" -version >/dev/null 2>&1 || fail '安装后的 ffprobe 未通过 -version 自检。'
log "安装完成：$install_dir/ffmpeg 与 $install_dir/ffprobe"
log "来源与 SHA-256 记录：$install_dir/$MANIFEST_NAME"
log '请重新打开 AI Video Cutty；它会优先查找此用户级目录。'
