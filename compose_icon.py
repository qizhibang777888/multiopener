#!/usr/bin/env python3
"""绘制「多开助手」应用图标 (1024x1024)
设计：蓝紫渐变圆角方块背景 + 两个白色窗口卡片斜向堆叠 + 绿色加号徽章
      （通用"多开/复制应用"隐喻，不绑定任何具体 App）
"""
from PIL import Image, ImageFilter, ImageDraw
import os

BUILD = "/Users/qizhibang/deepseekWork/multiopener-build"
CANVAS = 1024

# ---- 背景主体：824px 圆角方块 + 垂直渐变 ----
BODY = (100, 100, 924, 924)
RADIUS = 185
TOP = (122, 140, 255)     # #7A8CFF
BOTTOM = (106, 75, 232)   # #6A4BE8

def ascii_map(img, w=56):
    h = max(1, w // 2)
    a = img.split()[3].resize((w, h), Image.BOX)
    rows = []
    for y in range(h):
        row = ""
        for x in range(w):
            v = a.getpixel((x, y))
            row += "#" if v > 200 else "+" if v > 120 else "." if v > 40 else " "
        rows.append(row)
    return "\n".join(rows)

canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

# 渐变
grad = Image.new("RGB", (824, 824))
gd = ImageDraw.Draw(grad)
for y in range(824):
    t = y / 823
    c = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    gd.line([(0, y), (824, y)], fill=c)

# 圆角 mask
mask = Image.new("L", (824, 824), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle((0, 0, 824, 824), radius=RADIUS, fill=255)
canvas.paste(grad, (100, 100), mask)

# ---- 工具：带 padding 的软阴影 ----
def shadow_of(layer_shape_draw, blur, opacity, dx, dy):
    """layer_shape_draw: 在透明图上画出形状（黑色 alpha 图）"""
    a = layer_shape_draw.split()[3].point(lambda v: round(v * opacity))
    sh = Image.new("RGBA", layer_shape_draw.size, (0, 0, 0, 0))
    sh.putalpha(a)
    pad = int(blur * 3 + max(abs(dx), abs(dy)) + 8)
    w, h = sh.size
    big = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    big.paste(sh, (pad, pad))
    big = big.filter(ImageFilter.GaussianBlur(blur))
    return big, dx - pad, dy - pad

def as_canvas(layer, cx, cy):
    tmp = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    tmp.paste(layer, (round(cx - layer.width / 2), round(cy - layer.height / 2)))
    return tmp

# ---- 窗口卡片 ----
def make_tile(size, radius):
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius,
                        fill=(255, 255, 255, 255), outline=(120, 130, 160, 50), width=2)
    # 两条浅灰"内容条"，暗示应用窗口
    d.rounded_rectangle((size * 0.16, size * 0.22, size * 0.68, size * 0.22 + size * 0.06),
                        radius=size * 0.03, fill=(214, 220, 236, 255))
    d.rounded_rectangle((size * 0.16, size * 0.36, size * 0.52, size * 0.36 + size * 0.06),
                        radius=size * 0.03, fill=(214, 220, 236, 255))
    return tile

back = make_tile(300, 68)
front = make_tile(340, 76)
bcx, bcy = 610, 410
fcx, fcy = 480, 545

# 后层卡片：淡投影 + 轻微压暗
sh, ox, oy = shadow_of(back, 26, 0.22, 0, 12)
canvas = Image.alpha_composite(canvas, as_canvas(sh, bcx + ox, bcy + oy))
dim_a = back.split()[3].point(lambda v: round(v * 0.12))
dim = Image.new("RGBA", back.size, (208, 216, 235, 0))
dim.putalpha(dim_a)
back_dim = Image.alpha_composite(back, dim)
canvas = Image.alpha_composite(canvas, as_canvas(back_dim, bcx, bcy))

# 前层卡片：投影落在后层上
sh, ox, oy = shadow_of(front, 28, 0.32, 12, 16)
canvas = Image.alpha_composite(canvas, as_canvas(sh, fcx + ox, fcy + oy))
canvas = Image.alpha_composite(canvas, as_canvas(front, fcx, fcy))

# ---- 加号徽章 ----
bcx2, bcy2 = 740, 740
ring_d, green_d = 252, 224

ring = Image.new("RGBA", (ring_d, ring_d), (0, 0, 0, 0))
ImageDraw.Draw(ring).ellipse((0, 0, ring_d - 1, ring_d - 1), fill=(255, 255, 255, 255))
sh, ox, oy = shadow_of(ring, 22, 0.35, 0, 10)
canvas = Image.alpha_composite(canvas, as_canvas(sh, bcx2 + ox, bcy2 + oy))
canvas = Image.alpha_composite(canvas, as_canvas(ring, bcx2, bcy2))

badge = Image.new("RGBA", (green_d, green_d), (0, 0, 0, 0))
bd = ImageDraw.Draw(badge)
bd.ellipse((0, 0, green_d - 1, green_d - 1), fill=(52, 199, 89, 255))
# 白色加号（圆头）
arm = green_d * 0.42   # 臂长
th = green_d * 0.185   # 臂厚
c = green_d / 2
r = th / 2
bd.rounded_rectangle((c - arm, c - r, c + arm, c + r), radius=r, fill=(255, 255, 255, 255))
bd.rounded_rectangle((c - r, c - arm, c + r, c + arm), radius=r, fill=(255, 255, 255, 255))
canvas = Image.alpha_composite(canvas, as_canvas(badge, bcx2, bcy2))

# ---- 校验 ----
print("--- 图标轮廓 ---")
print(ascii_map(canvas))
alpha = canvas.split()[3]
print("内容边界:", alpha.getbbox())
for label, (x, y) in {
    "前卡片中心": (480, 545), "后卡片露出区": (700, 300),
    "徽章绿色区": (740, 660), "徽章白色环": (740 - 118, 740),
    "背景左上": (160, 160), "前卡投影区": (700, 640),
}.items():
    print(f"  {label} ({x},{y}) -> {canvas.getpixel((x, y))}")

canvas.save(os.path.join(BUILD, "composed_1024.png"))
canvas.resize((512, 512), Image.LANCZOS).save(os.path.join(BUILD, "preview_512.png"))

iconset = os.path.join(BUILD, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
sizes = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}
half = canvas.resize((512, 512), Image.LANCZOS)
for name, sz in sizes.items():
    (canvas if sz >= 512 else half).resize((sz, sz), Image.LANCZOS).save(os.path.join(iconset, name))
print("iconset 已生成:", iconset)
