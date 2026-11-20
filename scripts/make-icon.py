#!/usr/bin/env python3
"""Generates the Nagi app icon (DECISIONS D29).

Nagi (凪) is the sea gone calm when the wind stops. The icon is seen from just above still water:
one drop has fallen, its rings spread, the water rebounds, and the next drop hangs above, about to
fall. It stands for the calm itself and for nature arriving on it, not for any one effect.

Usage:
  scripts/make-icon.py [--render] [--out DIR]

Writes AppIcon.svg (1024x1024 on Apple's macOS icon grid: an 824x824 squircle centred in the
canvas) and, with --render, AppIcon-1024.png and AppIcon.icns, into App/AppIcon by default.
Rendering uses Quick Look (WebKit), sips, iconutil and ImageMagick's magick.
"""
import argparse, math, os, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
C = 512  # centre


def squircle(cx, cy, half, n=5.0, steps=720):
    """Superellipse close to Apple's continuous-corner icon shape."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{cx + half * math.copysign(abs(c) ** (2 / n), c):.2f},"
                   f"{cy + half * math.copysign(abs(s) ** (2 / n), s):.2f}")
    return "M" + " L".join(pts) + " Z"


BODY = squircle(C, C, 412)
HEAD = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'


CX, WY, HZ = 512, 640, 455     # landing point, horizon
FLAT = 0.19                    # a low view: rings are flat ellipses
DROP_Y, DROP_R = 352, 70

DEFS = f'''
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
 <stop offset="0" stop-color="#e9f1f8"/><stop offset="0.6" stop-color="#f4e4cf"/><stop offset="1" stop-color="#f1cfa0"/></linearGradient>
<linearGradient id="sea" x1="0" y1="0" x2="0" y2="1">
 <stop offset="0" stop-color="#d7e3ec"/><stop offset="0.18" stop-color="#9dbedb"/><stop offset="0.55" stop-color="#4f88bb"/><stop offset="1" stop-color="#1f5585"/></linearGradient>
<filter id="soft" x="-20%" y="-50%" width="140%" height="200%"><feGaussianBlur stdDeviation="14"/></filter>
<filter id="softer" x="-20%" y="-50%" width="140%" height="200%"><feGaussianBlur stdDeviation="5"/></filter>
<linearGradient id="lens" x1="0" y1="0" x2="0" y2="1">
 <stop offset="0" stop-color="#2f6aa0"/><stop offset="0.42" stop-color="#8db6da"/><stop offset="0.55" stop-color="#f6dcb4"/><stop offset="1" stop-color="#fbeedd"/></linearGradient>
<radialGradient id="shade" cx="0.5" cy="0.5" r="0.5"><stop offset="0.7" stop-color="#173e66" stop-opacity="0"/><stop offset="1" stop-color="#173e66" stop-opacity="0.55"/></radialGradient>
<linearGradient id="jet" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6fa2cf"/><stop offset="1" stop-color="#2a5f91"/></linearGradient>
<clipPath id="water"><rect x="0" y="{HZ}" width="1024" height="{1024-HZ}"/></clipPath>
'''

def lens_drop(cx, cy, r):
    """A drop as a lens: it shows the world upside down (water above, sky below), a rim, a highlight."""
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#lens)"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#shade)"/>'
            f'<ellipse cx="{cx - r*0.34}" cy="{cy - r*0.42}" rx="{r*0.26}" ry="{r*0.13}" fill="#fff" fill-opacity="0.95" transform="rotate(-28 {cx - r*0.34} {cy - r*0.42})"/>'
            f'<circle cx="{cx + r*0.42}" cy="{cy + r*0.5}" r="{r*0.07}" fill="#fff" fill-opacity="0.7"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r - 1.5}" fill="none" stroke="#ffffff" stroke-opacity="0.5" stroke-width="3"/>')

def ring(rx, w, o):
    ry = rx * FLAT
    # a crest lit from the far sky, its shadowed back face below
    return (f'<ellipse cx="{CX}" cy="{WY + w*0.9}" rx="{rx}" ry="{ry}" fill="none" stroke="#123c63" stroke-opacity="{o*0.55}" stroke-width="{w*1.1}"/>'
            f'<ellipse cx="{CX}" cy="{WY}" rx="{rx}" ry="{ry}" fill="none" stroke="#fdf3e4" stroke-opacity="{o}" stroke-width="{w}"/>')

def scene():
    rings = "".join(ring(rx, w, o) for rx, w, o in [(118, 11, 0.95), (196, 10, 0.8), (282, 9, 0.62), (376, 8, 0.44), (478, 7, 0.28)])
    warm_bands = "".join(f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="#f7cf98" fill-opacity="{o}" filter="url(#soft)"/>'
                         for x, y, rx, ry, o in [(700, HZ + 30, 260, 10, 0.75), (320, HZ + 58, 220, 9, 0.55), (760, HZ + 92, 200, 8, 0.45), (260, HZ + 128, 160, 7, 0.3)])
    crater = f'<ellipse cx="{CX}" cy="{WY + 4}" rx="86" ry="17" fill="#173e66" fill-opacity="0.55" filter="url(#softer)"/>'
    jet = (f'<path d="M{CX-40} {WY+2} C{CX-16} {WY-2} {CX-13} {WY-34} {CX-11} {WY-58} C{CX-10} {WY-70} {CX+10} {WY-70} {CX+11} {WY-58} '
           f'C{CX+13} {WY-34} {CX+16} {WY-2} {CX+40} {WY+2} Z" fill="url(#jet)"/>'
           f'<path d="M{CX-5} {WY-52} C{CX-5} {WY-30} {CX-8} {WY-14} {CX-16} {WY-4}" stroke="#fff" stroke-opacity="0.55" stroke-width="4" fill="none" stroke-linecap="round"/>')
    bead = lens_drop(CX, WY - 92, 17)
    return (f'<rect width="1024" height="{HZ+20}" fill="url(#sky)"/>'
            f'<rect y="{HZ}" width="1024" height="{1024-HZ}" fill="url(#sea)"/>'
            f'<rect y="{HZ-14}" width="1024" height="28" fill="#f3dcc0" filter="url(#soft)"/>'
            f'<g clip-path="url(#water)">{warm_bands}{rings}{crater}</g>'
            f'{jet}{bead}{lens_drop(CX, DROP_Y, DROP_R)}')

def svg():
    return f'''{HEAD}<defs>{DEFS}<clipPath id="body"><path d="{BODY}"/></clipPath>
<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.9"/>
<stop offset="0.5" stop-color="#fff" stop-opacity="0.15"/><stop offset="1" stop-color="#fff" stop-opacity="0.5"/></linearGradient></defs>
<g clip-path="url(#body)">{scene()}</g>
<path d="{BODY}" fill="none" stroke="url(#rim)" stroke-width="6"/></svg>
'''


def render(master, out):
    """AppIcon-1024.png and AppIcon.icns from the SVG master."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, master],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        png = os.path.join(tmp, os.path.basename(master) + ".png")
        # Quick Look paints a white background, so cut the outside away with a mask rendered the
        # same way (white squircle on black), keeping the anti-aliased edge. Nothing is drawn
        # outside the squircle (no drop shadow; only the rim's inner half shows), so the master
        # and the PNG match.
        mask_svg = os.path.join(tmp, "mask.svg")
        with open(mask_svg, "w") as f:
            f.write(f'{HEAD}<rect width="1024" height="1024" fill="#000"/><path d="{BODY}" fill="#fff"/></svg>')
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, mask_svg],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        big = os.path.join(out, "AppIcon-1024.png")
        subprocess.run(["magick", png, "(", os.path.join(tmp, "mask.svg.png"), "-colorspace", "gray", ")",
                        "-alpha", "off", "-compose", "CopyOpacity", "-composite", big], check=True)
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                subprocess.run(["sips", "-z", str(px), str(px), big, "--out", os.path.join(iconset, name)],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out, "AppIcon.icns")], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "App", "AppIcon"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    master = os.path.join(args.out, "AppIcon.svg")
    with open(master, "w") as f:
        f.write(svg())
    if args.render:
        render(master, args.out)
    print(f"wrote {os.path.relpath(args.out)}")


if __name__ == "__main__":
    main()
