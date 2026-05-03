#!/usr/bin/env python3
"""从设计稿几何生成 NWVPN / NewWorldVPN App Icon PNG（Pillow），并写入 BrickWallMark 矢量图集。

NewWorldVPN 菜单栏使用两套**非模板**小 PNG（已连接浅色 / 未连接灰色），避免 `MenuBarExtra` 里模板图无法按 foreground 区分颜色。
"""
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


def draw_menubar_brick(
    width_px: int,
    height_px: int,
    stroke_rgba: tuple[int, int, int, int],
) -> Image.Image:
    """透明底砖墙线框，与 brick-wall-mark 几何一致（用于菜单栏小图标）。"""
    w, h = max(4, width_px), max(4, height_px)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pad = 1
    wall_w = max(2, w - 2 * pad)
    wall_h = max(2, h - 2 * pad)
    left = pad + (w - 2 * pad - wall_w) // 2
    top = pad + (h - 2 * pad - wall_h) // 2
    stroke = max(1, min(int(round(1.75 / 28 * wall_w)), wall_w // 5))
    draw = ImageDraw.Draw(img)
    fg = stroke_rgba

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


# macOS AppIcon.appiconset 标准 10 槽（与 Xcode / design 一致）
MAC_APP_ICON_SPECS: list[tuple[str, int, str, str]] = [
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


def write_mac_app_icon_set(dest_appiconset: Path) -> None:
    dest_appiconset.mkdir(parents=True, exist_ok=True)
    mac_images = []
    for fname, dim, sz, sc in MAC_APP_ICON_SPECS:
        save_png(draw_app_icon(dim), dest_appiconset / fname)
        mac_images.append({"size": sz, "idiom": "mac", "filename": fname, "scale": sc})

    mac_contents = {"images": mac_images, "info": {"author": "xcode", "version": 1}}
    (dest_appiconset / "Contents.json").write_text(
        json.dumps(mac_contents, indent=2) + "\n", encoding="utf-8"
    )


def write_brick_wall_imageset(
    dest_imageset: Path,
    svg_src: Path,
    *,
    svg_filename: str,
) -> None:
    if dest_imageset.exists():
        shutil.rmtree(dest_imageset)
    dest_imageset.mkdir(parents=True, exist_ok=True)
    shutil.copy2(svg_src, dest_imageset / svg_filename)
    contents = {
        "images": [{"filename": svg_filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template",
        },
    }
    (dest_imageset / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )


def write_mac_menubar_brick_png_pair(
    catalog: Path,
    *,
    base_name: str,
    stroke_rgba: tuple[int, int, int, int],
    height_1x: int = 11,
) -> None:
    """两套独立图集，不用 template，颜色直接画进 PNG。"""
    w1 = max(3, int(round(height_1x * 30 / 20)))
    h1 = height_1x
    w2, h2 = w1 * 2, h1 * 2
    dest = catalog / f"{base_name}.imageset"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    save_png(draw_menubar_brick(w1, h1, stroke_rgba), dest / f"{base_name}.png")
    save_png(draw_menubar_brick(w2, h2, stroke_rgba), dest / f"{base_name}@2x.png")
    contents = {
        "images": [
            {"filename": f"{base_name}.png", "idiom": "mac", "scale": "1x"},
            {"filename": f"{base_name}@2x.png", "idiom": "mac", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (dest / "Contents.json").write_text(
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
    newworld_cat = root / "apps/macos/NewWorldVPN/Resources/Assets.xcassets"

    ios_icon = ios_cat / "AppIcon.appiconset"
    mac_icon = mac_cat / "AppIcon.appiconset"
    newworld_icon = newworld_cat / "AppIcon.appiconset"

    write_catalog_root(ios_cat)
    write_catalog_root(mac_cat)
    write_catalog_root(newworld_cat)

    write_brick_wall_imageset(ios_cat / "BrickWallMark.imageset", svg_src, svg_filename="BrickWallMark.svg")
    write_brick_wall_imageset(mac_cat / "BrickWallMark.imageset", svg_src, svg_filename="BrickWallMark.svg")

    # NewWorldVPN 菜单栏：小号彩色 PNG（非 template），Swift 用 `MenuBarBrickConnected` / `MenuBarBrickDisconnected`
    legacy_mb = newworld_cat / "MenuBarBrick.imageset"
    if legacy_mb.exists():
        shutil.rmtree(legacy_mb)
    # 浅色：在深色菜单栏上接近白；灰色：未连接时明显变暗
    write_mac_menubar_brick_png_pair(
        newworld_cat,
        base_name="MenuBarBrickConnected",
        stroke_rgba=(245, 247, 250, 255),
        height_1x=11,
    )
    write_mac_menubar_brick_png_pair(
        newworld_cat,
        base_name="MenuBarBrickDisconnected",
        stroke_rgba=(120, 124, 132, 255),
        height_1x=11,
    )

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

    write_mac_app_icon_set(mac_icon)
    write_mac_app_icon_set(newworld_icon)

    print(
        "Wrote",
        ios_icon,
        ",",
        mac_icon,
        ",",
        newworld_icon,
        "and NewWorldVPN MenuBarBrick* / NWVPN BrickWallMark imagesets",
    )


if __name__ == "__main__":
    main()
