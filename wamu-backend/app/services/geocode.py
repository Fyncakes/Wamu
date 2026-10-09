"""Kampala drop-off geocoding — Nominatim with a local neighborhood fallback."""

from __future__ import annotations

import logging
import re
from decimal import Decimal

import httpx

logger = logging.getLogger(__name__)

# Common Kampala places used in demo checkout (lat, lng).
_KAMPALA_PLACES: dict[str, tuple[float, float]] = {
    "kisaasi": (0.3668, 32.5969),
    "kisaas": (0.3668, 32.5969),
    "ntinda": (0.3544, 32.6168),
    "nakawa": (0.3370, 32.6200),
    "bukoto": (0.3535, 32.5960),
    "kololo": (0.3389, 32.5925),
    "kampala rd": (0.3136, 32.5811),
    "wandegeya": (0.3350, 32.5700),
    "makerere": (0.3290, 32.5705),
    "najeera": (0.3765, 32.6255),
    "kiwatule": (0.3688, 32.6230),
    "bugolobi": (0.3185, 32.6205),
    "luzira": (0.3005, 32.6450),
    "namugongo": (0.3980, 32.6510),
    "kira": (0.4000, 32.6400),
    "bweyogerere": (0.3630, 32.6670),
    "kansanga": (0.2955, 32.6055),
    "kabalagala": (0.2988, 32.5988),
    "munyonyo": (0.2735, 32.6180),
    "entebbe road": (0.2850, 32.5750),
    "najjera": (0.3765, 32.6255),
    "kulambiro": (0.3775, 32.6055),
    "kamwokya": (0.3415, 32.5835),
    "old kampala": (0.3155, 32.5675),
    "industrial area": (0.3120, 32.6050),
}


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", " ", s.lower()).strip()


def lookup_kampala_place(address: str | None) -> tuple[float, float] | None:
    if not address:
        return None
    n = _norm(address)
    if not n:
        return None
    for key, coords in _KAMPALA_PLACES.items():
        if key in n:
            return coords
    return None


async def geocode_kampala_address(address: str | None) -> tuple[Decimal, Decimal] | None:
    """Return (lat, lng) for a Kampala delivery address."""
    local = lookup_kampala_place(address)
    if local:
        return Decimal(str(local[0])), Decimal(str(local[1]))
    text = (address or "").strip()
    if len(text) < 4:
        return None
    q = text if "kampala" in text.lower() else f"{text}, Kampala, Uganda"
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            res = await client.get(
                "https://nominatim.openstreetmap.org/search",
                params={"q": q, "format": "json", "limit": 1, "countrycodes": "ug"},
                headers={"User-Agent": "WamuDelivery/1.0 (kampala-demo)"},
            )
        res.raise_for_status()
        rows = res.json()
        if not rows:
            return None
        lat = float(rows[0]["lat"])
        lng = float(rows[0]["lon"])
        if not (0.15 < lat < 0.55 and 32.35 < lng < 32.85):
            return None
        return Decimal(str(round(lat, 6))), Decimal(str(round(lng, 6)))
    except Exception:
        logger.info("Nominatim geocode failed for %r", text[:80])
        return None


def is_placeholder_dropoff(
    pickup_lat: float | None,
    pickup_lng: float | None,
    dropoff_lat: float | None,
    dropoff_lng: float | None,
) -> bool:
    if None in (pickup_lat, pickup_lng, dropoff_lat, dropoff_lng):
        return True
    return (
        abs((dropoff_lat or 0) - (pickup_lat or 0) - 0.008) < 0.0008
        and abs((dropoff_lng or 0) - (pickup_lng or 0) - 0.006) < 0.0008
    )
