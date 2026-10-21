"""Generate Ananta OTT launcher icons (adaptive + legacy square + legacy round).

Usage: python3 make_icons.py <icon.png> <android res dir>

Why: the artwork is a wide rounded square. Scaling it into an adaptive icon
let launcher masks (circle / squircle) cut its corners and text. Here the
emblem (A logo + ANANTA OTT) is placed inside the adaptive-icon safe zone over
a full-bleed dark background, so every mask shape shows it complete.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

src, res = Path(sys.argv[1]), Path(sys.argv[2])
art = Image.open(src).convert('RGBA')
# Emblem = globe + A logo + ANANTA OTT (no frame, no tagline/button row).
emblem = art.crop((70, 66, 442, 352))
# Feather the crop edges so the emblem melts into the background (no box).
_m = Image.new('L', emblem.size, 0)
ImageDraw.Draw(_m).rounded_rectangle((14, 14, emblem.width - 14, emblem.height - 14), radius=40, fill=255)
_m = _m.filter(ImageFilter.GaussianBlur(11))
_a = emblem.split()[3]
emblem.putalpha(Image.composite(_m, Image.new('L', emblem.size, 0), _a).point(lambda v: v))

BG_CENTER, BG_EDGE = (16, 7, 70), (4, 2, 30)


def background(size):
    """Full-bleed dark purple radial gradient (opaque, no transparency)."""
    small = 64
    g = Image.new('RGB', (small, small))
    px = g.load()
    c = (small - 1) / 2
    for y in range(small):
        for x in range(small):
            d = min(1.0, (((x - c) ** 2 + (y - c) ** 2) ** 0.5) / (small * 0.62))
            px[x, y] = tuple(int(BG_CENTER[i] + (BG_EDGE[i] - BG_CENTER[i]) * d) for i in range(3))
    return g.resize((size, size), Image.BICUBIC).convert('RGBA')


def place(canvas, em, fraction):
    """Centre emblem so its width is `fraction` of the canvas width."""
    w = int(canvas.width * fraction)
    h = int(em.height * w / em.width)
    e = em.resize((w, h), Image.LANCZOS)
    # soft purple glow behind the emblem
    glow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    glow.paste((150, 80, 255, 90), ((canvas.width - w) // 2, (canvas.height - h) // 2), e.split()[3])
    glow = glow.filter(ImageFilter.GaussianBlur(canvas.width * 0.025))
    canvas.alpha_composite(glow)
    canvas.alpha_composite(e, ((canvas.width - w) // 2, (canvas.height - h) // 2))


# --- Adaptive icon (Android 8+): 108dp canvas, safe zone = centre 66dp (61%).
S = 432
fg = Image.new('RGBA', (S, S), (0, 0, 0, 0))
place(fg, emblem, 0.58)
bgimg = background(S)
(res / 'drawable-nodpi').mkdir(parents=True, exist_ok=True)
fg.save(res / 'drawable-nodpi/ic_launcher_foreground.png')
bgimg.save(res / 'drawable-nodpi/ic_launcher_background_img.png')

# --- Legacy icons (Android 7 and older): square and round.
for d, px in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
    k = 4
    big = px * k
    base = background(big)
    place(base, emblem, 0.66)
    # round
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, big - 1, big - 1), fill=255)
    rnd = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    rnd.paste(base, (0, 0), mask)
    # square with rounded corners
    mask2 = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask2).rounded_rectangle((0, 0, big - 1, big - 1), radius=int(big * 0.22), fill=255)
    sq = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    sq.paste(base, (0, 0), mask2)
    (res / f'mipmap-{d}').mkdir(parents=True, exist_ok=True)
    sq.resize((px, px), Image.LANCZOS).save(res / f'mipmap-{d}/ic_launcher.png')
    rnd.resize((px, px), Image.LANCZOS).save(res / f'mipmap-{d}/ic_launcher_round.png')

# Fully transparent image for the Android 12+ system splash icon.
Image.new('RGBA', (288, 288), (0, 0, 0, 0)).save(res / 'drawable-nodpi/splash_transparent.png')
