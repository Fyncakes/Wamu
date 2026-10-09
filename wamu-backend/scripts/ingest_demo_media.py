"""Copy images_demo + video-demo into media_uploads/seed and refresh manifests.

Runs repeatedly: every image/video is copied with stable slugs and assigned
across the five demo shops so product grids stay fully imaged.

Usage:
  python -m scripts.ingest_demo_media
  python -m scripts.ingest_demo_media --seed   # also run seed_demo_images + seed_discover_videos --force
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import shutil
import subprocess
from pathlib import Path

from PIL import Image

logger = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
IMAGES_SRC = REPO / "images_demo"
VIDEOS_SRC = REPO / "video-demo"
SEED = ROOT / "media_uploads" / "seed"
PRODUCTS_DIR = SEED / "products"
SHOPS_DIR = SEED / "shops"
DEMO_DIR = SEED / "demo"

SHOP_KEYS = ("bakery", "food", "fashion", "phones", "grocery")

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".avif", ".gif"}
VIDEO_EXTS = {".mp4", ".webm", ".mov"}

# Filename keyword → shop
_SHOP_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("bakery", ("cake", "pastry", "bakery", "dessert", "birthday", "cream", "piped")),
    (
        "food",
        (
            "food",
            "grill",
            "breakfast",
            "chicken",
            "snack",
            "restaurant",
            "cook",
            "meal",
            "gourmet",
            "plate",
            "tilapia",
            "fruit",
            "veg",
            "market",
            "fresh",
            "sultan",
            "dubai",
        ),
    ),
    (
        "fashion",
        (
            "fashion",
            "cloth",
            "fold",
            "reel",
            "look",
            "shirt",
            "sofa",
            "furniture",
            "bedroom",
            "interior",
            "luxury",
            "bag",
        ),
    ),
    ("phones", ("phone", "mobile", "iphone", "pixel", "galaxy", "gadget", "photo")),
    ("grocery", ("grocery", "shopping", "bag", "pantry", "essentials", "matooke")),
]

PRODUCT_NAMES: dict[str, list[str]] = {
    "bakery": [
        "Birthday Sprinkle Cake",
        "Fresh Fruit Cake",
        "Vintage Piped Cake",
        "Anniversary Rose Cake",
        "Aesthetic Mini Cake",
        "Cream Ribbon Cake",
        "Marble Pastry Slice",
        "Chocolate Layer Cake",
        "Weekend Dessert Box",
        "Custom Celebration Cake",
    ],
    "food": [
        "Gourmet Appetizer Plate",
        "Meal Prep Bowl Set",
        "Chef Special Plate",
        "Weekend Grill Box",
        "Street Food Combo",
        "Power Lunch Tray",
        "Full English Breakfast",
        "Evening Snacks Plate",
        "Sultan's Chicken",
        "Fresh Market Plate",
    ],
    "fashion": [
        "Thrift Rack Mix",
        "Street Fit Drop 01",
        "Street Fit Drop 02",
        "Weekend Lookbook Tee",
        "Campus Everyday Fit",
        "Night Out Fit",
        "Ladies Display Bag",
        "Living Room Sofa Set",
        "Bedroom Furniture Pack",
        "Interior Style Bundle",
    ],
    "phones": [
        "Pixel Pro Lineup",
        "Galaxy Flip Blue",
        "Color Drop Phones",
        "Daily Driver Phone",
        "Creator Setup Pack",
        "Accessory Bundle",
        "iPhone Pack Special",
        "Mobile Shop Floor Pick",
        "Cinematic Store Deal",
        "Photo Trick Kit",
    ],
    "grocery": [
        "Fresh Market Box",
        "Weekly Essentials",
        "Snack Run Pack",
        "Green Grocer Mix",
        "Campus Pantry Kit",
        "Reusable Market Bags",
        "Roadside Fruit Mix",
        "Vegetable Market Bundle",
        "Smart Shopping Bags",
        "Daily Produce Pack",
    ],
}

PRICES: dict[str, list[str]] = {
    "bakery": ["85000", "65000", "75000", "120000", "35000", "55000", "42000", "95000", "48000", "110000"],
    "food": ["28000", "32000", "25000", "40000", "18000", "22000", "35000", "15000", "28000", "24000"],
    "fashion": ["45000", "65000", "70000", "35000", "55000", "90000", "120000", "850000", "1200000", "450000"],
    "phones": ["2500000", "3200000", "1800000", "950000", "450000", "85000", "2800000", "150000", "220000", "95000"],
    "grocery": ["45000", "38000", "22000", "28000", "32000", "12000", "25000", "30000", "15000", "20000"],
}


def _slugify(name: str) -> str:
    s = name.lower()
    s = re.sub(r"[^a-z0-9]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return (s or "clip")[:80]


def _guess_shop(name: str) -> str:
    low = name.lower()
    scores = {k: 0 for k in SHOP_KEYS}
    for shop, words in _SHOP_KEYWORDS:
        for w in words:
            if w in low:
                scores[shop] += 1
    best = max(scores, key=scores.get)
    if scores[best] == 0:
        # Round-robin fallback by hash
        return SHOP_KEYS[hash(low) % len(SHOP_KEYS)]
    return best


def _ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def _extract_poster(mp4: Path, jpg: Path) -> bool:
    if not _ffmpeg_available():
        return False
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-ss",
                "1",
                "-i",
                str(mp4),
                "-frames:v",
                "1",
                "-q:v",
                "3",
                str(jpg),
            ],
            check=True,
            capture_output=True,
            timeout=120,
        )
        return jpg.is_file() and jpg.stat().st_size > 0
    except (subprocess.SubprocessError, OSError) as e:
        logger.warning("ffmpeg poster failed for %s: %s", mp4.name, e)
        return False


def _to_jpeg(src: Path, dest: Path) -> bool:
    """Convert/copy image to JPEG for broad client support."""
    try:
        if src.suffix.lower() in {".jpg", ".jpeg"}:
            shutil.copy2(src, dest)
            return True
        with Image.open(src) as im:
            rgb = im.convert("RGB")
            dest.parent.mkdir(parents=True, exist_ok=True)
            rgb.save(dest, "JPEG", quality=88)
            return True
    except Exception as e:  # noqa: BLE001
        logger.warning("Skip image %s: %s", src.name, e)
        return False


def ingest_images() -> dict[str, list[str]]:
    """Copy images_demo → seed/products + shop logos/covers. Returns shop→relative paths."""
    PRODUCTS_DIR.mkdir(parents=True, exist_ok=True)
    SHOPS_DIR.mkdir(parents=True, exist_ok=True)
    by_shop: dict[str, list[str]] = {k: [] for k in SHOP_KEYS}
    if not IMAGES_SRC.is_dir():
        logger.error("Missing %s", IMAGES_SRC)
        return by_shop

    files = sorted(
        p for p in IMAGES_SRC.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTS
    )
    # Cycle assignment so every shop gets many images repeatedly.
    for i, src in enumerate(files):
        shop = _guess_shop(src.stem)
        # Also round-robin a share so thin categories still get coverage.
        if len(by_shop[shop]) > (len(files) // 4 + 2):
            shop = SHOP_KEYS[i % len(SHOP_KEYS)]
        slug = _slugify(src.stem) or f"img_{i}"
        dest_name = f"{shop}_{slug}.jpg"
        dest = PRODUCTS_DIR / dest_name
        if _to_jpeg(src, dest):
            rel = f"seed/products/{dest_name}"
            by_shop[shop].append(rel)
            # Duplicate into other shops every N images for "use repeatedly"
            if i % 5 == 0:
                for other in SHOP_KEYS:
                    if other == shop:
                        continue
                    dup_name = f"{other}_extra_{slug}.jpg"
                    dup = PRODUCTS_DIR / dup_name
                    if not dup.exists():
                        shutil.copy2(dest, dup)
                    by_shop[other].append(f"seed/products/{dup_name}")

    # Logos / covers: first two images per shop
    for shop, paths in by_shop.items():
        if not paths:
            continue
        logo_src = ROOT / "media_uploads" / paths[0]
        cover_src = ROOT / "media_uploads" / (paths[1] if len(paths) > 1 else paths[0])
        logo_dest = SHOPS_DIR / f"{shop}_logo.jpg"
        cover_dest = SHOPS_DIR / f"{shop}_cover.jpg"
        shutil.copy2(logo_src, logo_dest)
        shutil.copy2(cover_src, cover_dest)

    logger.info(
        "Ingested images: %s",
        {k: len(v) for k, v in by_shop.items()},
    )
    return by_shop


def write_shops_manifest(by_shop: dict[str, list[str]]) -> Path:
    data: dict = {}
    for shop in SHOP_KEYS:
        paths = by_shop.get(shop) or []
        names = PRODUCT_NAMES[shop]
        prices = PRICES[shop]
        products = []
        # Use every available image; cycle names/prices so all media appears.
        count = max(len(paths), len(names))
        for i in range(count):
            if not paths:
                break
            img = paths[i % len(paths)]
            products.append(
                {
                    "name": names[i % len(names)] if i < len(names) else f"{names[i % len(names)]} {i + 1}",
                    "price": prices[i % len(prices)],
                    "image": img,
                }
            )
        data[shop] = {
            "logo": f"seed/shops/{shop}_logo.jpg",
            "cover": f"seed/shops/{shop}_cover.jpg",
            "products": products,
        }
    out = SHOPS_DIR / "manifest.json"
    out.write_text(json.dumps(data, indent=2) + "\n")
    logger.info("Wrote %s (%s shops)", out, len(data))
    return out


def ingest_videos(poster_fallbacks: list[str]) -> list[dict]:
    DEMO_DIR.mkdir(parents=True, exist_ok=True)
    clips: list[dict] = []
    if not VIDEOS_SRC.is_dir():
        logger.error("Missing %s", VIDEOS_SRC)
        return clips

    files = sorted(
        p for p in VIDEOS_SRC.iterdir() if p.is_file() and p.suffix.lower() in VIDEO_EXTS
    )
    fb_i = 0
    for src in files:
        slug = _slugify(src.stem)
        shop = _guess_shop(src.stem)
        mp4_name = f"{slug}.mp4"
        dest = DEMO_DIR / mp4_name
        shutil.copy2(src, dest)
        poster = DEMO_DIR / f"{slug}.jpg"
        if not _extract_poster(dest, poster):
            # Reuse product stills as posters when ffmpeg missing
            if poster_fallbacks:
                fb = ROOT / "media_uploads" / poster_fallbacks[fb_i % len(poster_fallbacks)]
                fb_i += 1
                if fb.is_file():
                    shutil.copy2(fb, poster)
                else:
                    poster = None
            else:
                poster = None
        caption_bits = re.sub(r"[#@_]+", " ", src.stem)
        caption_bits = re.sub(r"\s+", " ", caption_bits).strip()[:72]
        entry = {
            "slug": slug,
            "caption": f"{caption_bits} — Chat to Order" if caption_bits else "Discover on Wamu",
            "tags": shop,
            "shop": shop,
            "video": f"seed/demo/{mp4_name}",
            "poster": f"seed/demo/{slug}.jpg" if poster and poster.is_file() else None,
        }
        clips.append(entry)

    # Repeat feed once so short libraries feel fuller
    if clips:
        clips = clips + [
            {
                **c,
                "slug": f"{c['slug']}_bis",
                "caption": (c.get("caption") or "Wamu") + " · again",
            }
            for c in clips
        ]

    out = DEMO_DIR / "manifest.json"
    # For bis entries, same video/poster paths (reuse files)
    serializable = []
    for c in clips:
        serializable.append({k: v for k, v in c.items() if v is not None})
    out.write_text(json.dumps(serializable, indent=2) + "\n")
    logger.info("Ingested %s video files → %s feed entries", len(files), len(clips))
    return clips


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    p = argparse.ArgumentParser()
    p.add_argument("--seed", action="store_true", help="Run DB seeders after ingest")
    args = p.parse_args()

    by_shop = ingest_images()
    write_shops_manifest(by_shop)
    all_imgs = [p for paths in by_shop.values() for p in paths]
    ingest_videos(all_imgs)

    if args.seed:
        import asyncio

        from scripts.seed_demo_images import seed_demo_images
        from scripts.seed_discover_videos import seed_discover_videos

        n_img = asyncio.run(seed_demo_images(force=True))
        n_vid = asyncio.run(seed_discover_videos(force=True))
        print(f"seeded_shops={n_img} seeded_videos={n_vid}")
    else:
        print("ingest_ok")


if __name__ == "__main__":
    main()
