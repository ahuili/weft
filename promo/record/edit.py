#!/usr/bin/env python3
"""把 record.sh 录的素材剪成介绍视频：片头 → 每一步一段（底部字幕）→ 片尾，段与段之间淡入淡出。
菜单栏那一条打模糊（App 名和状态栏图标）。
用法：python3 promo/record/edit.py   → dist/Weft-介绍.mp4、assets/demo.gif
需要本机 Chrome（截字幕卡）和 ffmpeg。"""
import os, re, subprocess, sys, tempfile, urllib.parse
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[1]
raw = here / 'raw'
out_dir = here / 'build'
out_dir.mkdir(exist_ok=True)
CHROME = os.environ.get('CHROME', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
owner = (re.search(r'GITHUB_OWNER:-([^}"]+)', (root / 'scripts/repo.env').read_text()) or [None, 'OWNER'])[1]
W, H, FPS, XF = 1920, 1080, 30, 0.4

# 每一步的字幕（按 marks.txt 里的名字对上）；[键] 画成键帽
CAPS = {
    '舞台模式': ('舞台模式', '双击右 [⌘] 选版式，眼前只留要用的几个窗口'),
    '格子里挑窗口': ('格子里直接挑', '空格子点一下，按数字就放进来'),
    '换版式': ('版式随手换', '左右 · 一主两辅 · 三栏 · 四宫格，窗口自动摆好'),
    '叠放': ('叠放', '一个格子叠几个窗口，[⌥] + 滚轮立体翻看'),
    '存成场景': ('场景', '一块屏上一组窗口，挑一个，整屏摆好'),
    '⌃← → 切场景': ('像切桌面一样切场景', '[⌃] [←] [→] 或四指左右滑，窗口不会丢在别的桌面'),
    '⌥Tab': ('[⌥] [Tab]', '按窗口切，不是按 App'),
    '场景工作台': ('场景工作台', '拖窗口进格子，搭好自己的场景'),
}

def sh(*a, **k):
    r = subprocess.run(a, capture_output=True, text=True, **k)
    if r.returncode: sys.exit(f'✗ {a[0]} 失败：\n{r.stderr[-2000:]}')
    return r.stdout

def card(name, **q):
    png = out_dir / f'{name}.png'
    url = (here / 'cards.html').as_uri() + '?' + urllib.parse.urlencode(q)
    with tempfile.TemporaryDirectory() as prof:
        sh(CHROME, '--headless=new', f'--user-data-dir={prof}', '--hide-scrollbars', '--allow-file-access-from-files',
           '--force-device-scale-factor=1', '--default-background-color=00000000', f'--window-size={W},{H}',
           f'--screenshot={png}', '--virtual-time-budget=1500', url)
    return png

# 1) 分段：marks.txt 里每一步到下一步
marks = [(float(t), n) for t, n in (l.split('\t', 1) for l in (raw / 'marks.txt').read_text().strip().splitlines())]
segs = []
for (t, n), (t2, _) in zip(marks, marks[1:]):
    key = next((k for k in CAPS if n.startswith(k) or k in n), None)
    if key: segs.append((max(0.5, t - 0.15), t2 - 0.1, CAPS[key]))
print(f'{len(segs)} 段，素材共 {segs[-1][1] - segs[0][0]:.1f} 秒')

# 2) 字幕卡、片头片尾
caps = [card(f'cap{i}', k='cap', t=c[0], s=c[1]) for i, (_, _, c) in enumerate(segs)]
intro, outro = card('intro', k='intro'), card('outro', k='outro', owner=owner)

def dur(p): return float(sh('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(p)))

# 3) 每段单独出一个片段（统一 1920×1080 / 30fps），最后用 xfade 接起来
src = str(raw / 'ext.mov')
clips = []
def clip(name, args):
    p = out_dir / f'{name}.mp4'
    sh('ffmpeg', '-v', 'error', '-y', *args, '-r', str(FPS), '-pix_fmt', 'yuv420p', '-c:v', 'libx264', '-crf', '18', '-preset', 'medium', '-an', str(p))
    clips.append(p)
    return p

clip('00-intro', ['-loop', '1', '-t', '3.2', '-i', str(intro), '-vf', f'scale={W}:{H},format=yuv420p'])
for i, ((a, b, _), cap) in enumerate(zip(segs, caps)):
    d = b - a
    # 菜单栏（素材最上面约 2.8%）打模糊；字幕卡淡入淡出
    fc = (f'[0:v]scale={W}:{H},setsar=1[v];'
          f'[v]split[base][top];[top]crop={W}:32:0:0,boxblur=luma_radius=14:luma_power=2:chroma_radius=7:chroma_power=2[mb];[base][mb]overlay=0:0[v2];'
          f'[1:v]format=rgba,fade=in:st=0.35:d=0.35:alpha=1,fade=out:st={d - 0.5:.2f}:d=0.35:alpha=1[c];'
          f'[v2][c]overlay=0:0:shortest=1')
    seg_src = src
    # 单独补录的段：raw/<字幕标题>.mov 存在就用它（比如场景工作台补录了一段有窗口的场景）
    alt = {'场景工作台': raw / 'studio.mov'}.get(segs[i][2][0])
    if alt and alt.exists():
        seg_src, a, d = str(alt), 0.8, min(8.6, dur(alt) - 1.0)
    clip(f'{i + 1:02d}-seg', ['-ss', f'{a:.2f}', '-t', f'{d:.2f}', '-i', seg_src, '-loop', '1', '-t', f'{d:.2f}', '-i', str(cap),
                             '-filter_complex', fc])
clip('99-outro', ['-loop', '1', '-t', '5', '-i', str(outro), '-vf', f'scale={W}:{H},format=yuv420p'])

ins, fc, last, off = [], [], '0:v', 0.0
for i, p in enumerate(clips):
    ins += ['-i', str(p)]
for i in range(1, len(clips)):
    off += dur(clips[i - 1]) - XF
    lab = f'x{i}'
    fc.append(f'[{last}][{i}:v]xfade=transition=fade:duration={XF}:offset={off:.3f}[{lab}]')
    last = lab
mp4 = root / 'dist' / 'Weft-介绍.mp4'
mp4.parent.mkdir(exist_ok=True)
sh('ffmpeg', '-v', 'error', '-y', *ins, '-filter_complex', ';'.join(fc), '-map', f'[{last}]',
   '-r', str(FPS), '-pix_fmt', 'yuv420p', '-c:v', 'libx264', '-crf', '20', '-preset', 'slow', '-movflags', '+faststart', str(mp4))
print(f'✓ {mp4}（{dur(mp4):.1f} 秒，{mp4.stat().st_size / 1e6:.1f} MB）')

# 4) README 用的 GIF：960 宽、12 帧、1.4 倍速，两遍调色板
gif = root / 'assets' / 'demo.gif'
pal = out_dir / 'palette.png'
vf = 'setpts=PTS/1.4,fps=12,scale=960:-1:flags=lanczos'
sh('ffmpeg', '-v', 'error', '-y', '-i', str(mp4), '-vf', f'{vf},palettegen=max_colors=160:stats_mode=diff', str(pal))
sh('ffmpeg', '-v', 'error', '-y', '-i', str(mp4), '-i', str(pal), '-lavfi', f'{vf}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle', str(gif))
print(f'✓ {gif}（{gif.stat().st_size / 1e6:.1f} MB）')
