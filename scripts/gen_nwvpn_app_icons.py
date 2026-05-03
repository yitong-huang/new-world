#!/usr/bin/env python3
"""从设计稿几何生成 NWVPN App Icon PNG（Pillow），并写入 BrickWallMark 矢量图集。"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

from PIL import Image, ImageDraw


def lerp_color(
    t: float, a: tuple[int, int, int], b: tuple[int, int, int]
) -> tuple[int, int, int]:
    return (
        int(a[0] + (b[0] - a[0]) * t),
        int(a[1] + (b[1] - a[1]) * t),
        int(a[2] + (b[2] - a[2]) * t),
    )


def draw_app_icon(size: int) -> Image.Image:
    s = max(16, size)
    c_top = (26, 74, 122)
    c_bot = (12, 31, 54)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    layer = Image.new("RGB", (s, s))
    ld = ImageDraw.Draw(layer)
    for y in range(s):
        t = y / max(s - 1, 1)
        ld.line([(0, y), (s, y)], fill=lerp_color(t, c_top, c_bot))
    corner_r = max(2, int(s * 0.2211))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius=corner_r, fill=255)
    lr = layer.convert("RGBA")
    lr.putalpha(mask)
    img.alpha_composite(lr)

    wall_w = int(round(s * 510 / 1024))
    wall_h = int(round(wall_w * 20 / 30))
    cx, cy = s // 2, s // 2
    left = cx - wall_w // 2
    top = cy - wall_h // 2
    stroke = max(1, min(int(round(1.75 / 28 * wall_w)), wall_w // 5))
    fg = (248, 250, 252, 255)
    draw = ImageDraw.Draw(img)

    def ix(inner_x: float) -> float:
        return left + (inner_x - 1) / 28 * wall_w

    def iy(inner_y: float) -> float:
        return top + (inner_y - 1) / 18 * wall_h

    right = ix(29)
    bottom = iy(19)
    draw.rectangle([ix(1), iy(1), right, bottom], outline=fg, width=stroke)
    y_m1, y_m2 = iy(7), iy(13)
    draw.line([(ix(1), y_m1), (ix(29), y_m1)], fill=fg, width=stroke)
    draw.line([(ix(1), y_m2), (ix(29), y_m2)], fill=fg, width=stroke)
    draw.line([(ix(15), iy(1)), (ix(15), iy(7))], fill=fg, width=stroke)
    draw.line([(ix(8), iy(7)), (ix(8), iy(13))], fill=fg, width=stroke)
    draw.line([(ix(22), iy(7)), (ix(22), iy(13))], fill=fg, width=stroke)
    draw.line([(ix(15), iy(13)), (ix(15), iy(19))], fill=fg, width=stroke)
    return img


def save_png(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")


def write_brick_wall_imageset(dest_imageset: Path, svg_src: Path) -> None:
    dest_imageset.mkdir(parents=True, exist_ok=True)
    shutil.copy2(svg_src, dest_imageset / "BrickWallMark.svg")
    contents = {
        "images": [{"filename": "BrickWallMark.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template",
        },
    }
    (dest_imageset / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )


def write_catalog_root(catalog: Path) -> None:
    catalog.mkdir(parents=True, exist_ok=True)
    p = catalog / "Contents.json"
    if not p.exists():
        p.write_text(
            json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
            encoding="utf-8",
        )


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    svg_src = root / "design/icons/brick-wall-mark.svg"
    ios_cat = root / "apps/ios/NWVPN/App/Assets.xcassets"
    mac_cat = root / "apps/macos/NWVPN/App/Assets.xcassets"
    ios_icon = ios_cat / "AppIcon.appiconset"
    mac_icon = mac_cat / "AppIcon.appiconset"

    write_catalog_root(ios_cat)
    write_catalog_root(mac_cat)
    write_brick_wall_imageset(ios_cat / "BrickWallMark.imageset", svg_src)
    write_brick_wall_imageset(mac_cat / "BrickWallMark.imageset", svg_src)

    # iOS：单槽 1024（Xcode 15+）
    save_png(draw_app_icon(1024), ios_icon / "AppIcon-1024.png")

    ios_contents = {
        "images": [
            {
                "filename": "AppIcon-1024.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ios_icon / "Contents.json").write_text(
        json.dumps(ios_contents, indent=2) + "\n", encoding="utf-8"
    )

    # macOS：标准 10 张
    mac_specs: list[tuple[str, int, str, str]] = [
        ("icon_16x16.png", 16, "16x16", "1x"),
        ("icon_16x16@2x.png", 32, "16x16", "2x"),
        ("icon_32x32.png", 32, "32x32", "1x"),
        ("icon_32x32@2x.png", 64, "32x32", "2x"),
        ("icon_128x128.png", 128, "128x128", "1x"),
        ("icon_128x128@2x.png", 256, "128x128", "2x"),
        ("icon_256x256.png", 256, "256x256", "1x"),
        ("icon_256x256@2x.png", 512, "256x256", "2x"),
        ("icon_512x512.png", 512, "512x512", "1x"),
        ("icon_512x512@2x.png", 1024, "512x512", "2x"),
    ]
    mac_images = []
    for fname, dim, sz, sc in mac_specs:
        save_png(draw_app_icon(dim), mac_icon / fname)
        mac_images.append(
            {"size": sz, "idiom": "mac", "filename": fname, "scale": sc}
        )

    mac_contents = {"images": mac_images, "info": {"author": "xcode", "version": 1}}
    (mac_icon / "Contents.json").write_text(
        json.dumps(mac_contents, indent=2) + "\n", encoding="utf-8"
    )
    print("Wrote", ios_icon, "and", mac_icon)


if __name__ == "__main__":
    main()
