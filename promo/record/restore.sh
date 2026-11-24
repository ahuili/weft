#!/bin/zsh
# 录完还原：退出 Weft → 把录之前备份的数据放回去 → 重新打开（每块屏摆回录之前的场景）
set -euo pipefail
BK=${1:-$HOME/Library/Application\ Support/Weft.backup-before-video-2026-11-24}
DIR=$HOME/Library/Application\ Support/Weft
[[ -d $BK ]] || { echo "没有备份：$BK"; exit 1; }
osascript -e 'quit app "Weft"' || true
for i in {1..20}; do pgrep -f Applications/Weft.app >/dev/null || break; sleep 0.5; done
rsync -a --delete "$BK/" "$DIR/"
open ~/Applications/Weft.app
echo "已还原：$DIR"
