"""Rasterize the repository's simple geometric app mark into macOS icon sizes."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import json

root = Path(__file__).resolve().parents[1]
assets = root / "NotchBeat/Assets.xcassets/AppIcon.appiconset"
assets.mkdir(parents=True, exist_ok=True)
size = 1024
mask = Image.new("L", (size, size)); d = ImageDraw.Draw(mask)
d.rounded_rectangle((92, 92, 932, 932), radius=190, fill=255)
background = Image.new("RGBA", (size, size))
draw = ImageDraw.Draw(background)
for y in range(size):
    fraction = y / size
    draw.line((0, y, size, y), fill=(int(55 - 34 * fraction), int(67 - 43 * fraction), int(75 - 46 * fraction), 255))
background.putalpha(mask)
glow = Image.new("RGBA", (size, size)); gd = ImageDraw.Draw(glow)
gd.ellipse((240, 405, 800, 690), fill=(54, 247, 174, 105))
glow = glow.filter(ImageFilter.GaussianBlur(80))
glow.putalpha(Image.composite(glow.getchannel("A"), Image.new("L", (size, size)), mask))
background = Image.alpha_composite(background, glow)
draw = ImageDraw.Draw(background)
draw.rounded_rectangle((94, 94, 930, 930), radius=188, outline=(129, 155, 162, 95), width=3)
draw.rounded_rectangle((182, 343, 842, 646), radius=125, fill=(2, 4, 5, 255), outline=(86, 111, 111, 145), width=3)
draw.rounded_rectangle((246, 407, 421, 582), radius=42, fill=(70, 138, 128, 255))
draw.rounded_rectangle((255, 414, 412, 574), radius=36, outline=(184, 240, 219, 90), width=2)
# A vector music note, drawn from primitives so the icon has no font dependency.
draw.line((342, 453, 342, 528), fill=(234, 255, 245, 255), width=12)
draw.line((341, 455, 374, 447), fill=(234, 255, 245, 255), width=12)
draw.ellipse((309, 511, 348, 540), fill=(234, 255, 245, 255))
for x, height in [(515, 55), (558, 114), (601, 168), (644, 85), (687, 133), (730, 55)]:
    draw.rounded_rectangle((x, 494-height/2, x+17, 494+height/2), radius=8, fill=(103, 250, 184, 255))
# Small camera silhouette above the expanded island.
draw.rounded_rectangle((418, 210, 606, 268), radius=29, fill=(2, 4, 5, 255))
draw.ellipse((552, 231, 570, 249), fill=(24, 46, 47, 255))
background.save(root / "AppIcon.png")
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = pt * scale
        name = f"icon_{pt}x{pt}@{scale}x.png"
        background.resize((pixels, pixels), Image.Resampling.LANCZOS).save(assets / name)
        images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
(assets / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))
print("Generated macOS app icon assets")
