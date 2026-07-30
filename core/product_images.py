"""
Generate flat-illustration product shots with Pillow.

Used by the ``seed_demo_data`` command so the demo catalogue has real image
files without downloading anything. Everything is drawn locally, so there is no
network dependency and no third-party image licensing to worry about.
"""

from io import BytesIO

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = 900

# Candidate fonts, in preference order. Falls back to Pillow's bitmap font.
_FONT_PATHS = [
    "/System/Library/Fonts/Supplemental/Futura.ttc",
    "/System/Library/Fonts/Supplemental/Avenir Next.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial.ttf",
]

# Silhouettes as normalised (0..1) polygons, scaled to the canvas at draw time.
SHAPES = {
    "tshirt": {
        "body": [
            (0.30, 0.24), (0.41, 0.17), (0.45, 0.22), (0.55, 0.22), (0.59, 0.17),
            (0.70, 0.24), (0.81, 0.37), (0.72, 0.45), (0.68, 0.39), (0.68, 0.83),
            (0.32, 0.83), (0.32, 0.39), (0.28, 0.45), (0.19, 0.37),
        ],
        "collar": (0.435, 0.205, 0.565, 0.265),
    },
    "jacket": {
        "body": [
            (0.28, 0.22), (0.40, 0.16), (0.50, 0.26), (0.60, 0.16), (0.72, 0.22),
            (0.83, 0.38), (0.74, 0.47), (0.70, 0.41), (0.70, 0.85), (0.30, 0.85),
            (0.30, 0.41), (0.26, 0.47), (0.17, 0.38),
        ],
        "lapels": [
            [(0.40, 0.16), (0.50, 0.26), (0.44, 0.40), (0.38, 0.24)],
            [(0.60, 0.16), (0.50, 0.26), (0.56, 0.40), (0.62, 0.24)],
        ],
        "placket": (0.487, 0.26, 0.513, 0.85),
    },
    "boot": {
        "body": [
            (0.33, 0.17), (0.57, 0.17), (0.58, 0.45), (0.63, 0.56), (0.75, 0.62),
            (0.79, 0.69), (0.79, 0.74), (0.28, 0.74), (0.28, 0.55), (0.32, 0.46),
        ],
        "sole": (0.26, 0.74, 0.81, 0.80),
        "cuff": (0.31, 0.17, 0.59, 0.24),
    },
}


def _load_font(size):
    for path in _FONT_PATHS:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default(size)


def _scale(points, size):
    return [(x * size, y * size) for x, y in points]


def _box(rect, size):
    return [rect[0] * size, rect[1] * size, rect[2] * size, rect[3] * size]


def _shade(colour, factor):
    """Lighten (factor > 1) or darken (factor < 1) an RGB tuple."""
    return tuple(max(0, min(255, int(c * factor))) for c in colour)


def _luminance(colour):
    r, g, b = colour
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _background(size, tint):
    """
    A soft neutral gradient so the product pops off the page. Only a trace of
    the product colour is mixed in — tinting the backdrop to match the garment
    (navy on blue, tan on tan) destroys the contrast.
    """

    def mix(base):
        return tuple(int(base[i] * 0.92 + tint[i] * 0.08) for i in range(3))

    top = mix((250, 250, 248))
    bottom = mix((228, 228, 223))
    bg = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        bg.putpixel(
            (0, y),
            tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )
    return bg.resize((size, size), Image.BILINEAR)


def render_product_image(shape, colour, label, size=SIZE):
    """Render one product shot and return it as JPEG bytes."""
    if shape not in SHAPES:
        raise ValueError(f"unknown shape {shape!r}; expected one of {sorted(SHAPES)}")

    spec = SHAPES[shape]
    canvas = _background(size, colour).convert("RGBA")

    # Soft drop shadow: draw the silhouette offset, blur it, composite beneath.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    offset = size * 0.018
    sd.polygon(
        [(x + offset, y + offset) for x, y in _scale(spec["body"], size)],
        fill=(0, 0, 0, 70),
    )
    if "sole" in spec:
        rect = _box(spec["sole"], size)
        sd.rounded_rectangle(
            [rect[0] + offset, rect[1] + offset, rect[2] + offset, rect[3] + offset],
            radius=size * 0.02,
            fill=(0, 0, 0, 70),
        )
    canvas = Image.alpha_composite(
        canvas, shadow.filter(ImageFilter.GaussianBlur(size * 0.02))
    )

    d = ImageDraw.Draw(canvas)
    # Pale garments need a darker outline to stay legible against the backdrop.
    outline = _shade(colour, 0.45 if _luminance(colour) > 200 else 0.65)
    line_w = max(2, int(size * 0.005))

    d.polygon(_scale(spec["body"], size), fill=colour, outline=outline, width=line_w)

    if "sole" in spec:
        d.rounded_rectangle(
            _box(spec["sole"], size),
            radius=size * 0.02,
            fill=_shade(colour, 0.55),
            outline=outline,
            width=line_w,
        )
    if "cuff" in spec:
        d.rounded_rectangle(
            _box(spec["cuff"], size),
            radius=size * 0.012,
            fill=_shade(colour, 1.25),
            outline=outline,
            width=line_w,
        )
    if "collar" in spec:
        d.ellipse(_box(spec["collar"], size), fill=_shade(colour, 1.3), outline=outline, width=line_w)
    for lapel in spec.get("lapels", []):
        d.polygon(_scale(lapel, size), fill=_shade(colour, 1.2), outline=outline, width=line_w)
    if "placket" in spec:
        d.rectangle(_box(spec["placket"], size), fill=_shade(colour, 0.75))

    # Caption
    font = _load_font(int(size * 0.045))
    text = label.upper()
    bbox = d.textbbox((0, 0), text, font=font)
    d.text(
        ((size - (bbox[2] - bbox[0])) / 2, size * 0.90),
        text,
        font=font,
        fill=_shade(colour, 0.45),
    )

    buf = BytesIO()
    canvas.convert("RGB").save(buf, format="JPEG", quality=88, optimize=True)
    return buf.getvalue()
