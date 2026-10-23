#!/usr/bin/env python3
"""Generate app icons from the brand logo.

The source artwork is a square logo on a white background. We place it on a white
squircle (Apple's macOS grid: 824 px artwork inside a 1024 px canvas) so it reads as a
proper app icon instead of a floating mark, then export:

  Assets/AppIcon.icns        macOS bundle icon (16…1024)
  Assets/AppIcon.ico         Windows exe + tray icon (16…256)
  Assets/AppIcon-1024.png    master PNG (also used by CI / docs)

Usage:
  python3 scripts/make_icons.py "~/Downloads/logo.png"
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

CANVAS = 1024
ARTWORK = 824          # Apple's rounded-square grid inside the canvas
RADIUS = 185           # ~22% of ARTWORK
OFFSET = (CANVAS - ARTWORK) // 2


def load_logo(path: Path) -> Image.Image:
    logo = Image.open(path).convert("RGB")
    side = max(logo.width, logo.height)
    if logo.width != logo.height:
        # Centre non-square art on a white square first.
        square = Image.new("RGB", (side, side), "white")
        square.paste(logo, ((side - logo.width) // 2, (side - logo.height) // 2))
        logo = square
    return logo.resize((ARTWORK, ARTWORK), Image.LANCZOS)


def build_icon(logo_path: Path) -> Image.Image:
    logo = load_logo(logo_path)

    # Compose artwork on white first, then clip everything to the squircle. Clipping last
    # matters: the logo's own white background would otherwise poke through the corners.
    plate = Image.new("RGBA", (ARTWORK, ARTWORK), (255, 255, 255, 255))
    inset = 26
    art = logo.resize((ARTWORK - inset * 2, ARTWORK - inset * 2), Image.LANCZOS)
    plate.paste(art, (inset, inset))

    mask = Image.new("L", (ARTWORK, ARTWORK), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, ARTWORK - 1, ARTWORK - 1], radius=RADIUS, fill=255)
    plate.putalpha(mask)

    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.paste(plate, (OFFSET, OFFSET), plate)
    return icon


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        raise SystemExit(2)

    source = Path(sys.argv[1]).expanduser()
    root = Path(__file__).resolve().parent.parent
    assets = root / "Assets"
    assets.mkdir(exist_ok=True)

    icon = build_icon(source)
    icon.save(assets / "AppIcon-1024.png")

    iconset = root / "build" / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        # @2x variants expected by iconutil
        if size * 2 <= 1024:
            icon.resize((size * 2, size * 2), Image.LANCZOS).save(
                iconset / f"icon_{size}x{size}@2x.png"
            )

    import subprocess

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(assets / "AppIcon.icns")],
        check=True,
    )

    icon.save(
        assets / "AppIcon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    for name in ("AppIcon.icns", "AppIcon.ico", "AppIcon-1024.png"):
        path = assets / name
        print(f"{path.relative_to(root)}  {path.stat().st_size / 1024:.0f} KB")


if __name__ == "__main__":
    main()
