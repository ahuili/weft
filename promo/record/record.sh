#!/bin/zsh
# 录介绍视频的原始素材：开演示模式（窗口内容全部毛玻璃），用 weft ctl 按顺序驱动真的 Weft，同时录两块屏。
# 用法：promo/record/record.sh [外接屏在 ctl 里的序号，默认 1]
# 产出：promo/record/raw/ext.mov、marks.txt（每一步开始的秒数，剪辑和加字幕用）
# 录之前：Weft 数据先备份（这些操作会改动正摆着的场景），录完用 restore.sh 还原。
set -uo pipefail
cd "$(dirname "$0")"
W=~/Applications/Weft.app/Contents/MacOS/Weft
D=${1:-1}                       # 外接屏在 weft ctl 里的序号（0 起）
RAW=raw; rm -rf $RAW; mkdir -p $RAW
c() { $W ctl "$@"; }
now() { python3 -c 'import time;print(time.time())'; }

# 外接屏的范围（CG 坐标），鼠标要放到它上面：版式盘、切换器都弹在鼠标所在的屏
read EX EY EW EH <<< $($W displays | awk -F'\t' -v n=$((D+1)) 'NR==n+1 { gsub(/[(),]/," ",$3); split($3,a," "); print a[1], a[2], a[3], a[4] }')
CX=$(( EX + EW / 2 )); CY=$(( EY + EH / 2 ))
echo "外接屏 $EX $EY ${EW}x$EH，中心 $CX,$CY"

# 各挑几个不同 App 的窗口（只取编号和 App 名，不看标题）
typeset -a IDS
for app in "Google Chrome" "备忘录" "Tabby" "Haven" "Telegram" "钉钉" "Herdr" "微信"; do
  id=$($W list 2>/dev/null | grep -E "^[0-9]+ +$app " | head -1 | awk '{print $1}')
  [[ -n $id ]] && IDS+=$id
done
echo "用的窗口：${IDS[*]}"
(( ${#IDS} >= 4 )) || { echo "窗口不够 4 个"; exit 1; }

trap 'c demo off; c hide' EXIT INT TERM   # 不管怎么结束，都把演示模式关掉
c demo on; c hide
c hover $CX $CY; sleep 3   # 等每个窗口的模糊截图到位

# 两块屏一起录（-v 录视频，-V 秒数，-C 带鼠标）
LEN=${LEN:-75}
screencapture -v -C -V $LEN -D 2 $RAW/ext.mov &
T0=$(now); sleep 1.2
mark() { printf '%.2f\t%s\n' $(( $(now) - T0 )) "$1" >> $RAW/marks.txt; }

mark "舞台模式：弹出版式盘"
c hover $CX $CY; c stagekey; sleep 2.2
c layoutkey 3; sleep 1.5            # 一主两辅
mark "格子里挑窗口"
c picker $D 1; sleep 1.5; c pickkey 1; sleep 1.2
c picker $D 2; sleep 1.2; c pickkey 1; sleep 2

mark "换版式"
# 换版式后有空格子，Weft 会自动弹「这个格子放谁」：这里直接填好，再把那个面板关掉
c layout triple $D; sleep 0.4; c assign $D 0 $IDS[1]; c assign $D 1 $IDS[2]; c assign $D 2 $IDS[3]; sleep 0.3; c hide; sleep 2.4
c layout quad $D; sleep 0.4; c assign $D 3 $IDS[4]; sleep 0.3; c hide; sleep 2.4
c layout split $D; sleep 0.3; c hide; sleep 2.4

mark "叠放"
c stack $D 0 $IDS[5]; sleep 1.6
c stack $D 0 $IDS[6]; sleep 1.6
c fan $D 0 1; sleep 1.6; c fan $D 0 2; sleep 1.4; c wheelend; sleep 2

mark "存成场景，切场景"
c scenes $D; sleep 2.2; c scenes-move 1; sleep 1; c scenes-move 1; sleep 1.2; c scenes-apply; sleep 0.3; c hide; sleep 2.4

mark "⌃← → 切场景"
# 只走一步：走过最后一个场景就是开空桌面
c peek $D 1; sleep 1.4; c peek-end; sleep 2.4
c peek $D -1; sleep 1.4; c peek-end; sleep 2.4

mark "⌥Tab"
c quick 1; sleep 1.2; c quick 1; sleep 1.2; c quick-end; c hide; sleep 2

mark "场景工作台"
c studio; sleep 6; c studio-hide; sleep 1.5

mark "结束"
wait
c demo off
echo "录好了：$(pwd)/$RAW"
cat $RAW/marks.txt
