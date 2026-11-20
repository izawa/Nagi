#!/usr/bin/env python3
# Draws the gallery's desktop backgrounds for effects that use windows (moss): the two windows of
# WindowLayout's "overlap" arrangement (1280 x 720 points at 2x), holding the reading text, over a
# plain desktop, light and dark. Writes App/Sources/Nagi/Resources/desk-{light,dark}.png.
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

resources = Path(__file__).resolve().parent.parent / 'App/Sources/Nagi/Resources'
W, H, S = 2560, 1440, 2
windows = [(110, 130, 700, 440), (520, 250, 640, 400)]  # back to front, points (WindowLayout "overlap")


def make(theme):
    top, bottom = ((120, 138, 150), (70, 84, 96)) if theme == 'light' else ((40, 46, 54), (18, 20, 24))
    image = Image.new('RGB', (W, H))
    draw = ImageDraw.Draw(image)
    for y in range(H):
        t = y / H
        draw.line([(0, y), (W, y)], fill=tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3)))
    text = Image.open(resources / f'reading-{theme}.png').convert('RGB')
    for x, y, w, h in windows:
        x, y, w, h = x * S, y * S, w * S, h * S
        shadow = Image.new('L', (W, H), 0)
        ImageDraw.Draw(shadow).rounded_rectangle([x, y + 20, x + w, y + h + 20], 32, fill=120)
        image.paste((0, 0, 0), mask=shadow.filter(ImageFilter.GaussianBlur(40)))
        mask = Image.new('L', (W, H), 0)
        ImageDraw.Draw(mask).rounded_rectangle([x, y, x + w, y + h], 32, fill=255)
        body = Image.new('RGB', (W, H), (255, 255, 255) if theme == 'light' else (30, 31, 34))
        body.paste(text.crop((140, 60, 140 + w - 40, 60 + h - 80)), (x + 20, y + 72))
        bar = ImageDraw.Draw(body)
        bar.rectangle([x, y, x + w, y + 56], fill=(236, 236, 236) if theme == 'light' else (44, 45, 48))
        for i, colour in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx = x + 32 + i * 40
            bar.ellipse([cx - 12, y + 16, cx + 12, y + 40], fill=colour)
        image.paste(body, mask=mask)
    image.save(resources / f'desk-{theme}.png', optimize=True)


for theme in ('light', 'dark'):
    make(theme)
