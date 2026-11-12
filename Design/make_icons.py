"""Regenerate the Amatsubame app icons' PNGs from their SVGs (docs/NAMING.md).

    python3 Design/make_icons.py Design/icons

The swift icons are drawn by hand, so the SVGs in `Design/icons/<App>/` are the source (viewBox
0 0 100 100): `-background`, `-background-dark`, `-foreground`, `-foreground-dark`,
`-foreground-mono` and `-icon`
(the flattened Default icon). This renders the 1024 px PNGs next to them; the `-icon` PNG is
made opaque, as the asset catalog requires. `make_layered_icon.py` builds each target's
`AppIcon.icon` from the same SVGs.

Renders with `rsvg-convert` (librsvg) when it's installed, otherwise with Quick Look
(`qlmanage`, built into macOS). Opaque icons use Pillow when it's installed, otherwise `sips`.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ICONS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), 'icons')
APPS = ['Yomu', 'Miru', 'Kiku', 'Hiku']
# Layers that get a PNG (the backgrounds are only ever used as SVG).
RENDERED = ['foreground', 'foreground-dark', 'foreground-mono', 'icon']


def render(svg_path, png_path):
    if shutil.which('rsvg-convert'):
        subprocess.run(['rsvg-convert', '-w', '1024', '-h', '1024', '-o', png_path, svg_path], check=True)
        return
    with tempfile.TemporaryDirectory() as folder:
        subprocess.run(['qlmanage', '-t', '-s', '1024', '-o', folder, svg_path], check=True, capture_output=True)
        shutil.move(os.path.join(folder, os.path.basename(svg_path) + '.png'), png_path)


def make_opaque(png_path):
    """The App Store icon has no alpha channel."""
    try:
        from PIL import Image
        Image.open(png_path).convert('RGB').save(png_path)
    except ImportError:
        # JPEG has no alpha; at full quality and 1024 px the round trip doesn't show.
        jpeg = png_path + '.jpg'
        subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '100', png_path, '--out', jpeg], check=True, capture_output=True)
        subprocess.run(['sips', '-s', 'format', 'png', jpeg, '--out', png_path], check=True, capture_output=True)
        os.remove(jpeg)


for name in APPS:
    folder = os.path.join(ICONS, name)
    for layer in RENDERED:
        svg_path = os.path.join(folder, f'{name}-{layer}.svg')
        png_path = os.path.join(folder, f'{name}-{layer}-1024.png')
        render(svg_path, png_path)
    make_opaque(os.path.join(folder, f'{name}-icon-1024.png'))
    print(name, 'done')
