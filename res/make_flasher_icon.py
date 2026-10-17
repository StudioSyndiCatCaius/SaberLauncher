# Builds res/flasher.ico from res/saber.ico: same tile and saber, amber blade, plus a
# "flash to drive" badge (down arrow into a tray). Run: python res/make_flasher_icon.py
import colorsys, os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
src = Image.open(os.path.join(HERE, "saber.ico"))
src.size = (256, 256)
src.load()
base = src.convert("RGBA")

# recolour the cyan blade/glow to amber; leave the dark tile and grey hilt alone
px = base.load()
for y in range(base.height):
    for x in range(base.width):
        r, g, b, a = px[x, y]
        if a == 0:
            continue
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if s > 0.25 and v > 0.35 and 0.45 < h < 0.62:
            h2 = 0.085  # amber
            nr, ng, nb = colorsys.hsv_to_rgb(h2, min(1, s * 1.05), v)
            px[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)

# badge, drawn 4x and downsampled for smooth edges
S = 4
badge = Image.new("RGBA", (256 * S, 256 * S), (0, 0, 0, 0))
d = ImageDraw.Draw(badge)
cx, cy, rad = 190 * S, 190 * S, 50 * S
d.ellipse([cx - rad - 6 * S, cy - rad - 6 * S, cx + rad + 6 * S, cy + rad + 6 * S], fill=(8, 10, 20, 255))  # cut-out ring
d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(92, 204, 255, 255))
ink = (8, 18, 32, 255)
w = 9 * S
# arrow shaft + head
d.rectangle([cx - w // 2, cy - 30 * S, cx + w // 2, cy + 4 * S], fill=ink)
d.polygon([(cx - 20 * S, cy - 4 * S), (cx + 20 * S, cy - 4 * S), (cx, cy + 18 * S)], fill=ink)
# tray
d.rectangle([cx - 26 * S, cy + 24 * S, cx + 26 * S, cy + 24 * S + w], fill=ink)
d.rectangle([cx - 26 * S, cy + 10 * S, cx - 26 * S + w, cy + 24 * S + w], fill=ink)
d.rectangle([cx + 26 * S - w, cy + 10 * S, cx + 26 * S, cy + 24 * S + w], fill=ink)
badge = badge.resize((256, 256), Image.LANCZOS)

icon = Image.alpha_composite(base, badge)
icon.save(os.path.join(HERE, "flasher.png"))
icon.save(os.path.join(HERE, "flasher.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("wrote flasher.ico")
