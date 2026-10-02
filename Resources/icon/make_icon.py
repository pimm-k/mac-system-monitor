from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math, struct, io

S = 2048                      # 2倍で描いて縮小（アンチエイリアス）
def sc(v): return int(v * S / 1024)

def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(len(a)))

def vgrad(w, h, top, bottom):
    g = Image.new("RGBA", (1, h))
    for y in range(h):
        g.putpixel((0, y), lerp(top, bottom, y/(h-1)))
    return g.resize((w, h))

def squircle_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- 本体（macOS アイコングリッド: 824px 角, 余白 100px）
x0, y0, x1, y1 = sc(100), sc(100), sc(924), sc(924)
R = sc(185)

# 影
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((x0, y0+sc(14), x1, y1+sc(14)), radius=R, fill=(0, 0, 0, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(sc(18)))
img.alpha_composite(shadow)

body = vgrad(S, S, (30, 48, 84, 255), (10, 16, 32, 255))
img.paste(body, (0, 0), squircle_mask((S, S), (x0, y0, x1, y1), R))

# 上部のハイライト
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
hd.rounded_rectangle((x0, y0, x1, y1), radius=R, outline=(255, 255, 255, 40), width=sc(4))
img.alpha_composite(hl)

# --- グラフパネル
px0, py0, px1, py1 = sc(196), sc(250), sc(828), sc(712)
panel = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pd = ImageDraw.Draw(panel)
pd.rounded_rectangle((px0, py0, px1, py1), radius=sc(36), fill=(6, 12, 26, 235),
                     outline=(70, 160, 255, 120), width=sc(4))
img.alpha_composite(panel)

# グリッド
grid = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(grid)
for i in range(1, 5):
    y = py0 + (py1 - py0) * i / 5
    gd.line((px0 + sc(10), y, px1 - sc(10), y), fill=(80, 150, 255, 45), width=sc(3))
for i in range(1, 8):
    x = px0 + (px1 - px0) * i / 8
    gd.line((x, py0 + sc(10), x, py1 - sc(10)), fill=(80, 150, 255, 45), width=sc(3))
img.alpha_composite(grid)

# 折れ線データ（CPU 使用率っぽい波形）
vals = [0.30, 0.34, 0.28, 0.42, 0.38, 0.55, 0.47, 0.72, 0.60, 0.66, 0.50, 0.58, 0.82, 0.70, 0.64, 0.76]
gx0, gx1 = px0 + sc(24), px1 - sc(24)
gy0, gy1 = py0 + sc(40), py1 - sc(24)
pts = []
for i, v in enumerate(vals):
    x = gx0 + (gx1 - gx0) * i / (len(vals) - 1)
    y = gy1 - (gy1 - gy0) * v
    pts.append((x, y))

# 塗りつぶし（上から下へフェード）
area_mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(area_mask).polygon(pts + [(gx1, gy1), (gx0, gy1)], fill=255)
fill = vgrad(S, S, (0, 0, 0, 0), (0, 0, 0, 0))
fill = Image.new("RGBA", (S, S), (0, 0, 0, 0))
fg = vgrad(1, gy1 - int(gy0) + sc(60), (40, 200, 255, 170), (40, 120, 255, 10))
fill.paste(fg.resize((S, fg.height)), (0, int(gy0) - sc(60)))
fill.putalpha(ImageChops.multiply(fill.getchannel("A"), area_mask))
img.alpha_composite(fill)

# 発光する線
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).line(pts, fill=(60, 210, 255, 200), width=sc(22), joint="curve")
glow = glow.filter(ImageFilter.GaussianBlur(sc(14)))
img.alpha_composite(glow)
line = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ld = ImageDraw.Draw(line)
ld.line(pts, fill=(170, 240, 255, 255), width=sc(11), joint="curve")
# 最新値のドット
lx, ly = pts[-1]
ld.ellipse((lx - sc(16), ly - sc(16), lx + sc(16), ly + sc(16)), fill=(255, 255, 255, 255))
img.alpha_composite(line)

# パネルの外にはみ出した部分を切る（念のため）
# --- 下部のメーター（CPU / メモリ / ディスク を表す 3 本のバー）
bars = [(0.78, (60, 170, 255)), (0.55, (175, 110, 255)), (0.35, (110, 220, 120))]
bx0, bx1 = sc(196), sc(828)
by = sc(762)
bh = sc(26)
gap = sc(18)
bw = (bx1 - bx0 - gap * 2) / 3
bl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bl)
for i, (v, col) in enumerate(bars):
    x = bx0 + i * (bw + gap)
    bd.rounded_rectangle((x, by, x + bw, by + bh), radius=bh // 2, fill=(255, 255, 255, 30))
    bd.rounded_rectangle((x, by, x + bw * v, by + bh), radius=bh // 2, fill=col + (255,))
img.alpha_composite(bl)

# 本体の形で切り抜き（影は残す）
final = img.resize((1024, 1024), Image.LANCZOS)
final.save("AppIcon_1024.png")

# --- .icns を PNG チャンクで作成
def png_bytes(size):
    b = io.BytesIO()
    final.resize((size, size), Image.LANCZOS).save(b, "PNG")
    return b.getvalue()

chunks = [(b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128), (b"ic08", 256),
          (b"ic09", 512), (b"ic10", 1024), (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512)]
body = b""
for t, sz in chunks:
    d = png_bytes(sz)
    body += t + struct.pack(">I", len(d) + 8) + d
with open("AppIcon.icns", "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
print("done")
