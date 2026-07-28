from collections import deque
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "new-logo.jpeg"
OUTPUTS = [
    ROOT / "assets",
    ROOT / "rentmect-admin-portal" / "src" / "assets",
    ROOT / "rentmect-admin-portal" / "public" / "assets",
    ROOT / "rentmect-client-portal" / "src" / "assets",
    ROOT / "rentmect-client-portal" / "public" / "assets",
]


def remove_connected_white_background(image):
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    width, height = rgba.size
    seen = set()
    queue = deque()

    def is_background(x, y):
        r, g, b, _ = pixels[x, y]
        return r > 238 and g > 238 and b > 238

    for x in range(width):
        queue.append((x, 0))
        queue.append((x, height - 1))
    for y in range(height):
        queue.append((0, y))
        queue.append((width - 1, y))

    while queue:
        x, y = queue.popleft()
        if (x, y) in seen or x < 0 or y < 0 or x >= width or y >= height:
            continue
        seen.add((x, y))
        if not is_background(x, y):
            continue
        pixels[x, y] = (255, 255, 255, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

    return rgba


def trim_transparent(image, padding=18):
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    if not bbox:
        return image
    left, top, right, bottom = bbox
    left = max(left - padding, 0)
    top = max(top - padding, 0)
    right = min(right + padding, image.width)
    bottom = min(bottom + padding, image.height)
    return image.crop((left, top, right, bottom))


def add_outline_and_shadow(image, outline=4):
    alpha = image.getchannel("A")
    expanded = alpha.filter(ImageFilter.MaxFilter(outline * 2 + 1))
    stroke = ImageChops.subtract(expanded, alpha)

    canvas = Image.new("RGBA", image.size, (255, 255, 255, 0))
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow.putalpha(alpha.filter(ImageFilter.GaussianBlur(3)))
    shadow = ImageChops.offset(shadow, 0, 2)
    canvas.alpha_composite(shadow)

    white_stroke = Image.new("RGBA", image.size, (255, 255, 255, 235))
    white_stroke.putalpha(stroke)
    canvas.alpha_composite(white_stroke)
    canvas.alpha_composite(image)
    return canvas


def contain(image, size, padding=0):
    max_width, max_height = size[0] - padding * 2, size[1] - padding * 2
    scale = min(max_width / image.width, max_height / image.height)
    resized = image.resize((round(image.width * scale), round(image.height * scale)), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", size, (255, 255, 255, 0))
    x = (size[0] - resized.width) // 2
    y = (size[1] - resized.height) // 2
    canvas.alpha_composite(resized, (x, y))
    return canvas


def white_badge(image, size, radius=18):
    badge = Image.new("RGBA", size, (255, 255, 255, 0))
    draw = ImageDraw.Draw(badge)
    draw.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=(255, 255, 255, 255))
    badge.alpha_composite(contain(image, size, padding=14))
    return badge


def pin_favicon(image):
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    width, height = rgba.size
    candidates = []
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a > 40 and r > 145 and g < 95 and b < 95:
                candidates.append((x, y))

    if not candidates:
        return contain(rgba, (128, 128), padding=8)

    center_x = width / 2
    near_center = [(x, y) for x, y in candidates if abs(x - center_x) < width * 0.18]
    points = near_center or candidates
    left = max(min(x for x, _ in points) - 16, 0)
    top = max(min(y for _, y in points) - 16, 0)
    right = min(max(x for x, _ in points) + 16, width)
    bottom = min(max(y for _, y in points) + 16, height)
    return contain(rgba.crop((left, top, right, bottom)), (128, 128), padding=10)


def save_everywhere(name, image):
    for directory in OUTPUTS:
        directory.mkdir(parents=True, exist_ok=True)
        image.save(directory / name, optimize=True)


def main():
    source = Image.open(SOURCE)
    cleaned = trim_transparent(remove_connected_white_background(source), padding=20)
    polished = add_outline_and_shadow(cleaned, outline=3)

    sidebar = contain(polished, (512, 180), padding=6)
    mobile = white_badge(polished, (360, 112), radius=14)
    favicon = pin_favicon(polished)

    save_everywhere("logo.png", sidebar)
    save_everywhere("logo-sidebar.png", sidebar)
    save_everywhere("logo-mobile.png", mobile)
    save_everywhere("favicon.png", favicon)


if __name__ == "__main__":
    main()
