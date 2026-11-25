#!/usr/bin/env python3
# Draws the site's desk backgrounds, "午後のメモ" (docs/SITE-DESK.md): one or two Mac windows on a
# desk, 1280 x 720 pt at 1.5x. Writes one-{light,dark}, two-{light,dark} and sparse-light as PNG,
# with the windows' positions as JSON for `nagi-render --windows`.
#   scripts/site/make-desk.py <output folder>
from pathlib import Path
import json, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
SC = 1.5  # 1280x720 pt -> 1920x1080 px
W, H = 1920, 1080
MINCHO = "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc"
TEXT = [
 "午後になって、窓の外の音が少し遠くなった。",
 "読みかけの頁に指を置いたまま、しばらく何もしないでいる。",
 "考えはまだ言葉にならず、机の上の光だけがゆっくり位置を変えていく。",
 "急いで書き留めるほどのことではない。",
 "それでも、この静かな時間のあとには、たいてい何かがまとまっている。",
 "",
 "紙の白は、時刻によって少しずつ色を変える。",
 "朝は青く、昼は硬く、夕方には温かい。",
 "その違いに気づくのは、手を止めたときだけだ。",
 "",
 "遠くで誰かが窓を開けた。風が一度だけ通り、また止む。",
 "海の上なら、これを凪と呼ぶ。",
]
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
OUT.mkdir(parents=True, exist_ok=True)
def pt(v): return int(round(v * SC))
def doc(draw, rect, dark, title, lines, size=15):
    x, y, w, h = [pt(v) for v in rect]
    paper = (28, 31, 36) if dark else (252, 252, 250)
    ink = (214, 216, 220) if dark else (40, 42, 46)
    bar = (44, 47, 53) if dark else (240, 240, 238)
    draw.rounded_rectangle([x, y, x + w, y + h], radius=pt(10), fill=paper)
    draw.rounded_rectangle([x, y, x + w, y + pt(28)], radius=pt(10), fill=bar)
    draw.rectangle([x, y + pt(18), x + w, y + pt(28)], fill=bar)
    for i, c in enumerate([(236, 106, 94), (244, 190, 80), (98, 197, 84)]):
        cx = x + pt(16 + i * 18); cy = y + pt(14)
        draw.ellipse([cx - pt(5), cy - pt(5), cx + pt(5), cy + pt(5)], fill=c if not dark else tuple(int(v * .8) for v in c))
    tf = ImageFont.truetype(MINCHO, pt(12), index=0)
    draw.text((x + w / 2, y + pt(14)), title, font=tf, fill=(120, 122, 126), anchor="mm")
    f = ImageFont.truetype(MINCHO, pt(size), index=0)
    ty = y + pt(64)
    for line in lines:
        if ty > y + h - pt(40): break
        draw.text((x + pt(56), ty), line, font=f, fill=ink)
        ty += pt(size * 2.0)
def shadowed(base, rects):
    sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(sh)
    for r in rects:
        x, y, w, h = [pt(v) for v in r]
        d.rounded_rectangle([x, y + pt(8), x + w, y + h + pt(8)], radius=pt(12), fill=(0, 0, 0, 70))
    return Image.alpha_composite(base, sh.filter(ImageFilter.GaussianBlur(pt(18))))
def make(name, dark, windows):
    desk = (34, 38, 44) if dark else (214, 220, 222)
    img = Image.new("RGBA", (W, H), desk + (255,))
    img = shadowed(img, [w["rect"] for w in windows])
    d = ImageDraw.Draw(img)
    for w in reversed(windows):  # back to front
        doc(d, w["rect"], dark, w.get("title", "メモ"), w.get("lines", TEXT))
    img.convert("RGB").save(OUT / f"{name}.png")
    json.dump({"size": [1280, 720], "windows": [{"id": i + 1, "rect": w["rect"]} for i, w in enumerate(windows)]},
              open(OUT / f"{name}.json", "w"))
one = [{"rect": [140, 70, 1000, 600], "title": "午後のメモ"}]
two = [{"rect": [150, 170, 640, 470], "title": "午後のメモ"},
       {"rect": [560, 90, 600, 420], "title": "読みかけ", "lines": TEXT[6:] + TEXT[:5]}]
sparse = [{"rect": [240, 140, 800, 440], "title": "下書き", "lines": ["", "", "海の上なら、これを凪と呼ぶ。"]}]
make("one-light", False, one); make("one-dark", True, one)
make("two-light", False, two); make("two-dark", True, two)
make("sparse-light", False, sparse)
