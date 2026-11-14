#!/usr/bin/env python3
"""Generate the original CLIProxyAPI Account Manager Tunnel icon.

The artwork is drawn from simple geometric primitives (no third-party art):
a rounded navy badge, a cyan shield, a keyhole representing account
management, and two connected nodes representing a secure tunnel between
Home Assistant and the server.

Outputs:
  haos-addon/icon.png  256x256 (Home Assistant add-on icon)
  haos-addon/logo.png  512x512 (Home Assistant add-on logo)
"""

from PIL import Image, ImageDraw

SCALE = 4
NAVY_TOP = (11, 18, 32, 255)
NAVY_BOTTOM = (22, 35, 58, 255)
BORDER = (45, 64, 92, 255)
SHIELD_FILL = (16, 42, 67, 255)
CYAN = (34, 211, 238, 255)
TEAL = (45, 212, 191, 255)
LIGHT = (226, 232, 240, 255)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def draw_icon(size):
    s = size * SCALE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Subtle vertical gradient inside a rounded square badge.
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    for y in range(s):
        t = y / max(1, s - 1)
        gd.line([(0, y), (s, y)], fill=(
            lerp(NAVY_TOP[0], NAVY_BOTTOM[0], t),
            lerp(NAVY_TOP[1], NAVY_BOTTOM[1], t),
            lerp(NAVY_TOP[2], NAVY_BOTTOM[2], t),
            255,
        ))
    badge_mask = rounded_mask(s, int(s * 0.22))
    img.paste(grad, (0, 0), badge_mask)

    d = ImageDraw.Draw(img)
    margin = int(s * 0.045)
    d.rounded_rectangle(
        (margin, margin, s - margin - 1, s - margin - 1),
        radius=int(s * 0.20),
        outline=BORDER,
        width=max(1, int(s * 0.008)),
    )

    # Shield geometry (top-left, top-right, shoulders, bottom point).
    cx = s / 2
    top = s * 0.20
    half_w = s * 0.235
    shoulder = s * 0.56
    bottom = s * 0.82
    shield = [
        (cx - half_w, top),
        (cx + half_w, top),
        (cx + half_w, shoulder),
        (cx, bottom),
        (cx - half_w, shoulder),
    ]
    d.polygon(shield, fill=SHIELD_FILL)
    d.line(shield + [shield[0]], fill=CYAN, width=max(2, int(s * 0.028)), joint="curve")

    # Two connected nodes: the secure tunnel endpoints.
    node_y = s * 0.365
    node_r = s * 0.042
    left = (cx - s * 0.105, node_y)
    right = (cx + s * 0.105, node_y)
    d.line([left, right], fill=TEAL, width=max(2, int(s * 0.022)))
    for node in (left, right):
        d.ellipse(
            (node[0] - node_r, node[1] - node_r, node[0] + node_r, node[1] + node_r),
            fill=TEAL,
        )

    # Keyhole: the account-management motif.
    key_cx, key_cy = cx, s * 0.545
    key_r = s * 0.058
    d.ellipse(
        (key_cx - key_r, key_cy - key_r, key_cx + key_r, key_cy + key_r),
        fill=CYAN,
    )
    stem = [
        (key_cx - s * 0.030, key_cy + s * 0.030),
        (key_cx + s * 0.030, key_cy + s * 0.030),
        (key_cx + s * 0.018, key_cy + s * 0.150),
        (key_cx - s * 0.018, key_cy + s * 0.150),
    ]
    d.polygon(stem, fill=CYAN)

    # A short base bar suggests a gateway platform without adding clutter.
    d.rounded_rectangle(
        (cx - s * 0.060, s * 0.742, cx + s * 0.060, s * 0.760),
        radius=int(s * 0.009),
        fill=TEAL,
    )

    return img.resize((size, size), Image.LANCZOS)


def main():
    icon = draw_icon(256)
    icon.save("haos-addon/icon.png", "PNG", optimize=True)

    logo = draw_icon(512)
    logo.save("haos-addon/logo.png", "PNG", optimize=True)

    for name in ("haos-addon/icon.png", "haos-addon/logo.png"):
        with Image.open(name) as im:
            print(f"{name}: {im.size[0]}x{im.size[1]} {im.mode} {im.format}")


if __name__ == "__main__":
    main()
