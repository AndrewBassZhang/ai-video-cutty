#!/bin/zsh
# Finder Media Preview's optional FFmpeg installer.
#
# This script intentionally uses only Homebrew's official installer.  It does
# not download a third-party FFmpeg binary or execute a third-party installer.

emulate -LR zsh
set -euo pipefail

# Pin the official installer to a reviewed upstream commit. Updating this URL
# requires updating the expected SHA-256 below in the same change.
readonly OFFICIAL_HOMEBREW_INSTALLER='https://raw.githubusercontent.com/Homebrew/install/cced90146ea6d3057c03a636b668fef177415eb3/install.sh'
readonly OFFICIAL_HOMEBREW_INSTALLER_SHA256='12479a24be3f5307eecac7cde670fad7118640f031229e964f544b1367b52a41'
readonly USTC_BOTTLE_DOMAIN='https://mirrors.ustc.edu.cn/homebrew-bottles'
readonly USTC_API_DOMAIN='https://mirrors.ustc.edu.cn/homebrew-bottles/api'

use_ustc_mirror=0
dry_run=0

log() { print -- "[Finder Media Preview] $*"; }
warn() { print -u2 -- "[Finder Media Preview] 注意：$*"; }
fail() { print -u2 -- "[Finder Media Preview] 失败：$*"; exit 1; }

usage() {
  cat <<'EOF'
用法：install_ffmpeg.sh [--use-ustc-mirror] [--official] [--dry-run]

  --use-ustc-mirror  本次 brew install 临时使用中科大 Homebrew bottles 镜像。
  --official         不使用镜像，全部走 Homebrew 默认官方源。
  --dry-run          只显示将执行的操作，不下载、不安装。
EOF
}

while (( $# )); do
  case "$1" in
    --use-ustc-mirror) use_ustc_mirror=1 ;;
    --official) use_ustc_mirror=0 ;;
    --dry-run) dry_run=1 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "不认识的参数：$1（可用 --help 查看用法）" ;;
  esac
  shift
done

[[ "$(uname -s)" == 'Darwin' ]] || fail '此安装脚本仅适用于 macOS。'

run() {
  if (( dry_run )); then
    log "演练：$*"
  else
    "$@"
  fi
}

find_brew() {
  local candidate
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      print -- "$candidate"
      return 0
    fi
  done
  return 1
}

find_ffmpeg() {
  local candidate
  if command -v ffmpeg >/dev/null 2>&1; then
    command -v ffmpeg
    return 0
  fi
  for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [[ -x "$candidate" ]]; then
      print -- "$candidate"
      return 0
    fi
  done
  return 1
}

if ffmpeg_path=$(find_ffmpeg); then
  log "已检测到 FFmpeg：$ffmpeg_path"
  "$ffmpeg_path" -version 2>/dev/null | head -n 1 || true
  log '无需重复安装。关闭此窗口即可。'
  exit 0
fi

log '本脚本将通过 Homebrew 安装 FFmpeg。安装过程可能要求输入本机账户密码，并会下载软件包。'
log '不会修改原始媒体文件；仅安装命令行工具。'

if (( ! dry_run && ! use_ustc_mirror )) && [[ -t 0 ]]; then
  print -n -- '[Finder Media Preview] 是否本次临时使用中科大 Homebrew bottles 镜像加速下载？[Y/n] '
  read -r mirror_answer
  case "${mirror_answer:l}" in
    ''|y|yes) use_ustc_mirror=1 ;;
    n|no) ;;
    *) warn '输入未识别，将使用 Homebrew 默认官方源。' ;;
  esac
fi

if ! xcode-select -p >/dev/null 2>&1; then
  log '未发现 Xcode Command Line Tools，正在请求 macOS 打开安装窗口。'
  if (( dry_run )); then
    log '演练：xcode-select --install'
  else
    xcode-select --install >/dev/null 2>&1 || true
    warn '请先在弹出的 macOS 窗口完成“Command Line Tools”安装，然后重新运行本脚本。'
    exit 0
  fi
fi

brew_path=''
if brew_path=$(find_brew); then
  log "已检测到 Homebrew：$brew_path"
else
  log '未检测到 Homebrew；将从 Homebrew 官方 GitHub 源下载安装脚本。'
  log "官方来源：$OFFICIAL_HOMEBREW_INSTALLER"
  if (( dry_run )); then
    log "演练：下载官方 Homebrew 安装脚本并以 /bin/bash 执行"
  else
    installer_file=$(mktemp -t finder-media-preview-homebrew.XXXXXX) || fail '无法创建临时安装文件。'
    trap 'rm -f -- "$installer_file"' EXIT HUP INT TERM
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --show-error \
      --output "$installer_file" "$OFFICIAL_HOMEBREW_INSTALLER" || fail '无法从 Homebrew 官方地址下载安装脚本。请检查网络后重试。'
    [[ -s "$installer_file" ]] || fail 'Homebrew 官方安装脚本为空，已取消。'
    installer_sha256=$(shasum -a 256 "$installer_file" | awk '{print $1}') || fail '无法计算 Homebrew 安装脚本的 SHA-256，已取消。'
    [[ "$installer_sha256" == "$OFFICIAL_HOMEBREW_INSTALLER_SHA256" ]] || fail "Homebrew 安装脚本校验失败，已取消（实际：$installer_sha256）。"
    grep -q 'Homebrew' "$installer_file" || fail '下载内容不是预期的 Homebrew 安装脚本，已取消。'
    /bin/bash "$installer_file"
    rm -f -- "$installer_file"
    trap - EXIT HUP INT TERM
  fi
  brew_path=$(find_brew) || fail 'Homebrew 安装结束后仍未找到 brew。请关闭此窗口后重新运行脚本，或按 Homebrew 官方文档完成安装。'
fi

# The command makes this process see a just-installed brew.  It does not edit
# the user's shell configuration; Homebrew's own installer handles that choice.
eval "$(\"$brew_path\" shellenv)"
log "Homebrew 架构：$("$brew_path" --prefix)"

if (( use_ustc_mirror )); then
  log '本次仅为 brew install ffmpeg 临时使用中科大 bottles 镜像；不会写入 shell 配置。'
  export HOMEBREW_BOTTLE_DOMAIN="$USTC_BOTTLE_DOMAIN"
  brew_major=$("$brew_path" --version | sed -n '1s/^Homebrew \([0-9][0-9]*\).*/\1/p')
  if [[ -n "$brew_major" && "$brew_major" -ge 4 ]]; then
    export HOMEBREW_API_DOMAIN="$USTC_API_DOMAIN"
    log "检测到 Homebrew $brew_major；本次也临时使用 USTC API 镜像。"
  fi
else
  log '使用 Homebrew 默认官方源。'
fi

log '开始安装 FFmpeg。这一步取决于网络和系统，可能需要几分钟。'
run "$brew_path" install ffmpeg

unset HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN

if (( dry_run )); then
  log '演练完成：未安装任何软件。'
  exit 0
fi

ffmpeg_path=$(find_ffmpeg) || fail 'brew 已完成，但没有找到 ffmpeg。请执行 brew doctor 后重新运行本脚本。'
log "FFmpeg 安装完成：$ffmpeg_path"
"$ffmpeg_path" -version 2>/dev/null | head -n 1 || true
log '现在可重新打开 Finder Media Preview，使用 A/B 裁切导出视频或音频。'
