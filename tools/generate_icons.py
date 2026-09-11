"""
Fetch official Lucide SVG icons and render high-resolution 64x64 pure white PNGs.
"""
import os
import io
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from PIL import Image
import resvg_py

# Map from target filename (without .png) to Lucide icon name on unpkg
ICONS = {
    "arrow-left": "arrow-left",
    "arrow-right": "arrow-right",
    "book-open": "book-open",
    "check": "check",
    "chevron-down": "chevron-down",
    "circle": "circle",
    "code": "code",
    "copy": "copy",
    "dot": "circle-dot",
    "ellipsis": "ellipsis",
    "file-text": "file-text",
    "folder": "folder",
    "git-branch": "git-branch",
    "git-fork": "git-fork",
    "globe": "globe",
    "log-out": "log-out",
    "maximize-2": "maximize-2",
    "menu": "menu",
    "minus": "minus",
    "move-horizontal": "move-horizontal",
    "panel-left": "panel-left",
    "plus": "plus",
    "search": "search",
    "send": "send",
    "settings": "settings",
    "sliders-horizontal": "sliders-horizontal",
    "square-terminal": "square-terminal",
    "square": "square",
    "trash": "trash",
    "x": "x",
    "sparkles": "sparkles",
}

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "icons")
os.makedirs(OUTPUT_DIR, exist_ok=True)

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ProjectUAI/1.0"
}

def fetch_and_render(item):
    filename, lucide_name = item
    url = f"https://unpkg.com/lucide-static@latest/icons/{lucide_name}.svg"
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=10) as resp:
            svg_text = resp.read().decode("utf-8")
        
        # Ensure stroke is white (#ffffff)
        svg_white = svg_text.replace("currentColor", "#ffffff")
        
        # Render at 64x64 with resvg
        png_data = resvg_py.svg_to_bytes(svg_white, width=64, height=64)
        
        # Validate that all non-transparent pixels are pure white (255, 255, 255)
        im = Image.open(io.BytesIO(png_data)).convert("RGBA")
        r, g, b, a = im.split()
        # Create image with solid white RGB and original alpha channel
        white_rgb = Image.new("RGB", im.size, (255, 255, 255))
        pure_white_im = Image.merge("RGBA", (*white_rgb.split(), a))
        
        out_path = os.path.join(OUTPUT_DIR, f"{filename}.png")
        pure_white_im.save(out_path, "PNG", optimize=True)
        print(f"[OK] {filename}.png (from {lucide_name}) -> {len(png_data)} bytes")
        return True
    except Exception as e:
        print(f"[ERROR] {filename} ({lucide_name}): {e}")
        return False

def main():
    print(f"Generating {len(ICONS)} high-res icons into {OUTPUT_DIR}...")
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(fetch_and_render, ICONS.items()))
    success_count = sum(1 for r in results if r)
    print(f"Done: {success_count}/{len(ICONS)} icons successfully rendered at 64x64 pure white!")

if __name__ == "__main__":
    main()
