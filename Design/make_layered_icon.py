#!/usr/bin/env python3
"""Builds an Icon Composer document (.icon) from an app's background and foreground SVGs.

    python3 Design/make_layered_icon.py Design/icons/Yomu Yomu/Resources/AppIcon.icon

The swift and its prop are an opaque glass layer (so the white throat, rump band and props stay
crisp). In Dark it uses `-foreground-dark.svg`: lighter greys and a faint rim, without which the
black wing, tail and body vanish on a dark background. In Tinted (and so Clear) it uses
`-foreground-mono.svg`, a light-bodied swift that the system's tint and glass can show. The background is a
layer of its own: the app's gradient, `-background-dark.svg` in Dark, and hidden in Tinted (and
so Clear), where the system draws its own; the fill (the gradient's end colours) shows there.
Check the result with Icon Composer's ictool, e.g.
    ictool AppIcon.icon --export-image --output-file out.png --platform iOS --rendition ClearLight \
        --width 256 --height 256 --scale 1
"""
import json
import os
import re
import shutil
import sys

source, output = sys.argv[1:3]
name = os.path.basename(source.rstrip('/'))
stops = re.findall(r'stop-color="(#[0-9A-Fa-f]{6})"', open(f'{source}/{name}-background.svg').read())


def srgb(hex_color):
    red, green, blue = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f'srgb:{red:.5f},{green:.5f},{blue:.5f},1.00000'


shutil.rmtree(output, ignore_errors=True)
os.makedirs(f'{output}/Assets')
for asset in ['foreground', 'foreground-dark', 'foreground-mono', 'background', 'background-dark']:
    shutil.copy(f'{source}/{name}-{asset}.svg', f'{output}/Assets/{asset}.svg')
document = {
    'fill': {
        'linear-gradient': [srgb(stops[0]), srgb(stops[-1])],
        # The same direction as the SVG's 150° gradient.
        'orientation': {'start': {'x': 0.25, 'y': 0.067}, 'stop': {'x': 0.75, 'y': 0.933}},
    },
    'groups': [
        {
            # Only the specializations name the image: a plain `image-name` overrides them.
            'layers': [{'name': 'foreground', 'glass': True,
                        'image-name-specializations': [{'value': 'foreground.svg'},
                                                       {'appearance': 'dark', 'value': 'foreground-dark.svg'},
                                                       {'appearance': 'tinted', 'value': 'foreground-mono.svg'}]}],
            'shadow': {'kind': 'neutral', 'opacity': 0.5},
            # Opaque, so the white bird stays crisp instead of milky.
            'translucency': {'enabled': False, 'value': 0.4},
        },
        {
            'layers': [{'name': 'background', 'glass': False,
                        'image-name-specializations': [{'value': 'background.svg'},
                                                       {'appearance': 'dark', 'value': 'background-dark.svg'}],
                        'hidden-specializations': [{'appearance': 'tinted', 'value': True}]}],
        },
    ],
    'supported-platforms': {'squares': 'shared'},
}
with open(f'{output}/icon.json', 'w') as file:
    json.dump(document, file, indent=2)
