#!/bin/bash
# 一行安装 Weft（下载 GitHub 上最新的发布版，装到 /Applications）：
#   curl -fsSL https://raw.githubusercontent.com/ahuili/weft/main/scripts/install.sh | bash
set -euo pipefail
OWNER="${WEFT_OWNER:-ahuili}"
REPO="${WEFT_REPO:-weft}"
DEST="${WEFT_DEST:-/Applications}"

[[ "$(uname)" == "Darwin" ]] || { echo "Weft 只支持 macOS"; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || { echo "Weft 需要 macOS 14 (Sonoma) 或更新"; exit 1; }

echo "▸ 查找最新版本…"
tag=$(curl -fsSL "https://api.github.com/repos/$OWNER/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p' | head -1)
[[ -n "$tag" ]] || { echo "没找到发布版本"; exit 1; }
ver=${tag#v}
url="https://github.com/$OWNER/$REPO/releases/download/$tag/Weft-$ver.zip"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "▸ 下载 Weft $ver…"
curl -fL --progress-bar "$url" -o "$tmp/Weft.zip"
ditto -x -k "$tmp/Weft.zip" "$tmp"

if pgrep -x Weft >/dev/null; then echo "▸ 退出正在运行的 Weft…"; pkill -x Weft || true; sleep 1; fi
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Weft.app"
cp -R "$tmp/Weft.app" "$DEST/"
# 还没有 Apple 公证：去掉隔离标记，否则 macOS 会拦着不让打开
xattr -dr com.apple.quarantine "$DEST/Weft.app" 2>/dev/null || true
echo "✓ 已安装到 $DEST/Weft.app"
open "$DEST/Weft.app"
