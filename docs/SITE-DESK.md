# サイトの背景「午後のメモ」の作り方

サイト（izawa.github.io/Nagi）の動画と静止画は、エフェクトを作業中の画面の上に重ねて見せている。その画面は、Mac のウインドウを 1〜2 枚置いた机を、Python（Pillow）で描いた絵である。ウインドウの題名は「午後のメモ」で、本文は凪の話の短い文章にしてある。実在のアプリの画面は写していない。

| ファイル | 中身 |
|---|---|
| `one-light.png`（1920×1080） | ライトの机に「午後のメモ」1 枚。komorebi・caustics・rain・ripples の背景。縮めてサイトの `assets/desk.jpg`（1600×900）にもした |
| `one-dark.png` | 同じ構図のダーク。fireflies の背景 |
| `two-light.png`・`two-dark.png` | 「午後のメモ」と「読みかけ」の 2 枚。moss・gems の背景（ウインドウの位置を `--windows` で渡す） |
| `sparse-light.png` | 「下書き」1 枚で、本文は 1 行だけ。波紋を試したときの背景 |
| `*.json` | ウインドウの位置（pt）。`nagi-render --windows` が読む |

## 1. 背景を描く

画面は 1280×720 pt を 1.5 倍した 1920×1080 px で描く。字はヒラギノ明朝 ProN。`scripts/site/make-desk.py`（Pillow）を走らせると、上の表の PNG と JSON が、引数のフォルダにできる。

```bash
python3 scripts/site/make-desk.py <背景のフォルダ>
```

決めてある値は次のとおり。

- 机: ライト (214, 220, 222)、ダーク (34, 38, 44)
- 紙: ライト (252, 252, 250)、ダーク (28, 31, 36)。字: ライト (40, 42, 46)、ダーク (214, 216, 220)
- 題名の帯: 高さ 28 pt、角の丸み 10 pt。信号の 3 色の丸は半径 5 pt で 18 pt おき（ダークは 8 割の明るさ）
- 本文: 15 pt、行送り 30 pt、左の余白 56 pt、帯の下 64 pt から書き始める。ウインドウの下 40 pt に入らない行は書かない
- 影: ウインドウを 8 pt 下にずらした黒（不透明度 70/255）を、18 pt でぼかす

サイトの `desk.jpg` は `one-light.png` を縮めたもの。

```bash
ffmpeg -loglevel error -y -i one-light.png -vf scale=1600:-2:flags=lanczos -q:v 3 desk.jpg
```

## 2. エフェクトを重ねて描く

`Tools/nagi-render` で、背景の上にエフェクトを描いた連番の PNG を作る。画面は 1920×1080 px で、物理の大きさ 597×336 mm（27 インチ相当）にした。`BG` は背景のフォルダ。

```bash
R=Tools/nagi-render/.build/release/nagi-render
C=(--size 1920x1080 --physical-mm 597x336)
$R komorebi --at 2026-06-10T15:30:00+09:00 --depth 120 --frames 420 $C --background $BG/one-light.png --output f.png
$R caustics --at 2026-06-10T12:00:00+09:00 --depth 120 --frames 420 $C --background $BG/one-light.png --output f.png
$R rain     --at 2026-06-10T17:00:00+09:00 --time 180 --depth 180 --frames 360 $C --background $BG/one-light.png --output f.png
$R ripples  --at 2026-06-10T18:30:00+09:00 --depth 120 --frames 300 --param ripples.height=3 $C --background $BG/one-light.png --output f.png
$R gems     --at 2026-06-10T21:00:00+09:00 --depth 120 --frames 360 --appearance dark --seed 3 --param gems.amount=4 $C \
            --background $BG/two-dark.png --windows $BG/two-dark.json --window-age 14400 --output f.png
$R fireflies --at 2026-06-10T22:00:00+09:00 --depth 300 --frames 420 --appearance dark --seed 3 $C \
            --background $BG/one-dark.png --output f.png
```

- 宝石と苔はウインドウの縁に生えるので、`--windows` で位置を渡し、`--window-age 14400`（4 時間置いたウインドウ）にする
- ダークの背景には `--appearance dark` を付ける
- 待機の動画（`idle`）は背景を `--background gray:1` にした

## 3. サイト用に縮めて書き出す

連番を 30 fps で、幅 1600 の WebM（VP9）と MP4（H.264）、90 枚目のポスター（JPEG）にする。蛍は明滅がそろっていて 90 枚目が暗いので、光っている 66 枚目をポスターにした。ループさせる動画は、末尾 1.5 秒と先頭 1.5 秒をクロスフェードでつなぐ（波紋はループさせない）。

`scripts/site/encode.sh` がこれを行う。

```bash
scripts/site/encode.sh <連番のフォルダ> ../Nagi-site/assets komorebi
scripts/site/encode.sh <連番のフォルダ> ../Nagi-site/assets ripples 0   # ループさせない
scripts/site/encode.sh <連番のフォルダ> ../Nagi-site/assets fireflies 1 66   # 光っている 66 枚目をポスターに
```
