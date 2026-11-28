#!/usr/bin/env python3
"""Writes the swift icons' SVGs (docs/NAMING.md ▸ Mascot and icons): for each app, the
`-foreground`, `-foreground-dark`, `-foreground-mono` and flattened `-icon` layers, on a 100 × 100
viewBox, next to its unchanged `-background` and `-background-dark`.

    python3 Design/make_swift_icons.py Design/icons

Then `make_icons.py` renders their PNGs and `make_layered_icon.py` builds each target's `.icon`.

The swift is a flat die-cut sticker: flat fills in one blue-slate family, a three-feather tuft (a
cartoon liberty: Pacific swifts have no crest), a big round head with a darker cap, a white rump
band, a pale throat, a deep forked tail, tiny feet, dark eyes with a sparkle and pink blush. One
white border goes round each icon's whole foreground, bird and prop together, so it reads on the
app's gradient and on Dark's grey. Each app keeps its pose and prop: Yomu reads a book in glasses,
Miru watches a screen star-eyed, Kiku listens with its eyes closed, Hiku looks through a magnifying
glass.

Tinted and Clear use only the mono layer's luminance, so there the bird is dark slate and its prop
solid white with bolder lines, on a mid-grey border: the prop is the brightest shape, and the four
icons read apart at a glance on a tinted Home Screen.
"""
import re
import sys
from pathlib import Path

ICONS = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "icons"

# Default and Dark use the same bird (the white border carries it on Dark's grey). Tinted and Clear
# keep only luminance: the mono bird is dark, its patches and blush in mid-tones (white ones read as
# spots), so the white prop stands out.
PALE, BLUSH, EYE, BILL = "#F2F4F8", "#FF7C98", "#17181F", "#1B1D24"
PALETTES = {
    "default": dict(body="#7F899C", cap="#6A7488", dark="#454E62", wing_edge="#9AA6BC",
                    throat=PALE, rump="#FFFFFF", blush=BLUSH, lens="#FFFFFF", border="#FFFFFF"),
    "mono": dict(body="#6A7281", cap="#565E6D", dark="#3A404C", wing_edge="#7C8494",
                 throat="#8A92A1", rump="#848C9B", blush="#7E8695", lens="#5A6271", border="#8C94A3"),
}
# Each app's prop ink in Default and Dark (mono's is white).
INK = {"Yomu": "#0B4F45", "Miru": "#4A1F63", "Kiku": "#6B2410", "Hiku": "#5E0F32"}
STAR = "M{x} {ya} Q{x1} {yb} {x2} {yc} Q{x1} {yd} {x} {ye} Q{x3} {yd} {x4} {yc} Q{x3} {yb} {x} {ya} Z"


def star_eye(cx):
    """A dark eye with a four-point star in it (Miru, watching)."""
    x, y = cx + 1.1, -8.5
    star = STAR.format(x=x, ya=y - 2.9, x1=x + 0.64, yb=y - 0.64, x2=x + 2.9, yc=y, yd=y + 0.64, ye=y + 2.9, x3=x - 0.64, x4=x - 2.9)
    return (f'<ellipse cx="{cx}" cy="-7.4" rx="4.6" ry="5.3" fill="{EYE}"/><path d="{star}" fill="#FFFFFF"/>'
            f'<circle cx="{cx - 1.8}" cy="-4.9" r="0.85" fill="#FFFFFF"/>')


def open_eye(cx):
    return (f'<ellipse cx="{cx}" cy="-7" rx="3.8" ry="4.4" fill="{EYE}"/>'
            f'<circle cx="{cx + 1.3}" cy="-8.7" r="1.35" fill="#FFFFFF"/><circle cx="{cx - 1.2}" cy="-5.2" r="0.6" fill="#FFFFFF"/>')


def closed_eye(cx):
    return f'<path d="M{cx - 4} -5.5 Q{cx} -9.5 {cx + 4} -5.5" fill="none" stroke="{EYE}" stroke-width="2.4" stroke-linecap="round"/>'


def bill(open_mouth):
    if open_mouth:
        return (f'<path d="M19.5 -4 Q29 -2 20.1 -0.2 Z" fill="{BILL}" stroke="{PALE}" stroke-width="1.1" stroke-linejoin="round"/>'
                f'<path d="M19.9 1.4 Q26 2.8 19.5 4.4 Z" fill="{BILL}" stroke="{PALE}" stroke-width="1.1" stroke-linejoin="round"/>'
                f'<path d="M20.2 -0.2 L20 1.4" stroke="#E0607A" stroke-width="1.4"/>')
    return f'<path d="M19.5 -3.2 Q28.5 -0.4 19.5 2.8 Z" fill="{BILL}" stroke="{PALE}" stroke-width="1.1" stroke-linejoin="round"/>'


def swift(uid, palette, eyes="open", mouth=False, extra=""):
    """The sticker swift on the current frame: body a circle of radius 24 at the origin, facing right."""
    p = PALETTES[palette]
    left, right = {"open": (open_eye, open_eye), "closed": (closed_eye, closed_eye),
                   "stars": (star_eye, star_eye), "left-only": (open_eye, None)}[eyes]
    face = (left(3.5) if left else "") + (right(14) if right else "")
    return f'''<defs><clipPath id="b{uid}"><circle r="24"/></clipPath></defs>
<path d="M-14 6 L-46 14 L-33 19 L-42 30 L-10 18 Z" fill="{p["dark"]}"/>
<path d="M2 21 l-1.5 5 M6.5 21.5 l0.5 5" fill="none" stroke="{p["dark"]}" stroke-width="1.8" stroke-linecap="round"/>
<path d="M2 -23 Q0 -29 4 -31 M6 -23.5 Q6 -30 10 -31 M9.5 -22.5 Q12 -27 15 -27" fill="none" stroke="{p["cap"]}" stroke-width="2.2" stroke-linecap="round"/>
<circle r="24" fill="{p["body"]}"/>
<g clip-path="url(#b{uid})">
<path d="M-24 -24 L24 -24 L24 -15 Q2 -21 -24 -6 Z" fill="{p["cap"]}"/>
<path d="M-26 0 Q-23 15 -8 25 L-14 30 L-32 10 Z" fill="{p["rump"]}"/>
<path d="M9 6 Q16 3.5 22 8 Q22.5 15 15.5 17 Q8.5 16.5 7.5 11 Q7.5 7.5 9 6 Z" fill="{p["throat"]}"/>
</g>
<path d="M-2 8 Q-12 18 -30 14 Q-38 10 -42 2 Q-26 8 -12 6 Z" fill="{p["dark"]}"/>
{face}{bill(mouth)}
<ellipse cx="-0.5" cy="2" rx="3.4" ry="2" fill="{p["blush"]}"/><ellipse cx="13" cy="3.4" rx="3" ry="1.8" fill="{p["blush"]}"/>
{extra}'''


def foreground(app, palette):
    """Bird and prop for one app, in the icon's 100 × 100 frame, before the border."""
    ink = INK[app] if palette == "default" else "#FFFFFF"
    uid = f"{app[0].lower()}{palette[0]}"
    if app == "Miru":
        screen, lines = ("#E9DDF6", "#C7B0E4") if palette == "default" else ("#A9B0BD", "#FFFFFF")
        tv = (f'<path d="M48.5 24 L36 9 M51.5 24 L66 7.5" stroke="{ink}" stroke-width="3" stroke-linecap="round"/>'
              f'<circle cx="36" cy="9" r="3" fill="#FFFFFF" stroke="{ink}" stroke-width="2"/><circle cx="66" cy="7.5" r="3" fill="#FFFFFF" stroke="{ink}" stroke-width="2"/>'
              f'<rect x="14" y="25" width="72" height="58" rx="14" fill="#FFFFFF" stroke="{ink}" stroke-width="3"/>'
              f'<rect x="21" y="32" width="58" height="44" rx="8" fill="{screen}"/>'
              f'<path d="M27 40 L37 40 M27 46 L33 46" stroke="{lines}" stroke-width="3" stroke-linecap="round"/>')
        return tv + f'<g transform="translate(57 64) rotate(-8) scale(0.86)">{swift(uid, palette, "stars", True)}</g>'
    if app == "Yomu":
        lines = "#8FC9B8" if palette == "default" else "#8A92A2"
        glasses = (f'<circle cx="3.2" cy="-7" r="5.8" fill="#FFFFFF" fill-opacity="0.25" stroke="{ink}" stroke-width="2.3"/>'
                   f'<circle cx="14.8" cy="-7" r="5.8" fill="#FFFFFF" fill-opacity="0.25" stroke="{ink}" stroke-width="2.3"/>'
                   f'<path d="M-2.6 -7.6 L-10 -9.8" stroke="{ink}" stroke-width="1.8" stroke-linecap="round"/>'
                   f'<path d="M8.9 -7.4 Q9 -9 9.2 -7.4" stroke="{ink}" stroke-width="1.6" fill="none"/>')
        bird = f'<g transform="translate(55 44) rotate(5) scale(0.9)">{swift(uid, palette, "open", False, glasses)}</g>'
        book = (f'<path d="M12 66 Q31 58 50 65 Q69 58 88 66 L88 88 Q69 81 50 87 Q31 81 12 88 Z" fill="#FFFFFF" stroke="{ink}" stroke-width="2.6" stroke-linejoin="round"/>'
                f'<path d="M50 65 L50 87" stroke="{ink}" stroke-width="2.4" stroke-linecap="round"/>'
                + "".join(f'<path d="M{a} {y} Q{b} {y - 4} {c} {y - 0.3}" fill="none" stroke="{lines}" stroke-width="2.2" stroke-linecap="round"/>'
                          for y in (72, 76.5, 81) for a, b, c in ((18, 31, 45), (55, 69, 82))))
        return bird + book
    if app == "Kiku":
        pads = "#FFC27A" if palette == "default" else "#FFFFFF"
        bird = f'<g transform="translate(52 58) scale(0.92)">{swift(uid, palette, "closed", False)}</g>'
        phones = (f'<path d="M24 41 Q24 8 52 8 Q80 8 80 41" fill="none" stroke="{ink}" stroke-width="4.5" stroke-linecap="round"/>'
                  f'<rect x="17" y="32" width="15" height="25" rx="7.5" fill="#FFFFFF" stroke="{ink}" stroke-width="3"/>'
                  f'<rect x="72" y="32" width="15" height="25" rx="7.5" fill="#FFFFFF" stroke="{ink}" stroke-width="3"/>'
                  f'<rect x="21" y="38" width="7" height="13" rx="3.5" fill="{pads}"/><rect x="76" y="38" width="7" height="13" rx="3.5" fill="{pads}"/>')
        return bird + phones
    if app == "Hiku":
        # The right eye is behind the lens, seen big through it.
        lens = (f'<path d="M23 3 L33 13" stroke="{ink}" stroke-width="5" stroke-linecap="round"/>'
                f'<circle cx="16" cy="-6" r="11" fill="{PALETTES[palette]["lens"]}" stroke="{ink}" stroke-width="3"/>'
                f'<ellipse cx="16" cy="-6" rx="5" ry="6" fill="{EYE}"/><circle cx="17.8" cy="-8.4" r="1.8" fill="#FFFFFF"/>'
                f'<circle cx="14.2" cy="-3.2" r="0.8" fill="#FFFFFF"/>')
        return f'<g transform="translate(46 54) rotate(-4) scale(0.98)">{swift(uid, palette, "left-only", False, lens)}</g>'
    raise ValueError(app)


def bolder(svg):
    """Mono's white prop lines, half as thick again."""
    return re.sub(r'stroke="#FFFFFF" stroke-width="([0-9.]+)"', lambda m: f'stroke="#FFFFFF" stroke-width="{float(m.group(1)) * 1.5:g}"', svg)


def sticker(svg, border="#FFFFFF"):
    """The die-cut border: every shape again in the border colour with a wider stroke, drawn first."""
    def white(tag):
        tag = re.sub(r'fill="(?!none)[^"]*"', f'fill="{border}"', tag)
        tag = re.sub(r'fill-opacity="[^"]*"', '', tag)
        if 'stroke="' in tag:
            tag = re.sub(r'stroke="[^"]*"', f'stroke="{border}"', tag)
            tag = re.sub(r'stroke-width="([0-9.]+)"', lambda m: f'stroke-width="{float(m.group(1)) + 6:g}"', tag)
        else:
            tag = tag.replace("/>", f' stroke="{border}" stroke-width="6" stroke-linejoin="round"/>', 1)
        return tag
    copy = re.sub(r'<(path|circle|ellipse|rect)\b[^>]*/>', lambda m: white(m.group(0)), svg)
    copy = re.sub(r'id="b(\w+)"', r'id="w\1"', copy).replace('url(#b', 'url(#w')
    return f'<g>{copy}</g>{svg}'


def svg(content):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="1024" height="1024">{content}</svg>\n'


def background(app):
    icon = (ICONS / app / f"{app}-background.svg").read_text()
    return re.sub(r"^<svg[^>]*>|</svg>\s*$", "", re.sub(r"<metadata>.*?</metadata>", "", icon, flags=re.S).strip())


if __name__ == "__main__":
    for app in INK:
        default = sticker(foreground(app, "default"))
        (ICONS / app / f"{app}-foreground.svg").write_text(svg(default))
        (ICONS / app / f"{app}-foreground-dark.svg").write_text(svg(default))
        mono = sticker(bolder(foreground(app, "mono")), border=PALETTES["mono"]["border"])
        (ICONS / app / f"{app}-foreground-mono.svg").write_text(svg(mono))
        (ICONS / app / f"{app}-icon.svg").write_text(svg(background(app) + default))
        print(app, "written")
