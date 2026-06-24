"""Google Places API (New) — gerçek mekan verisi (SPEC Faz 4). Sunucu-tarafı tool."""
import logging

import httpx

from core.config import settings

logger = logging.getLogger("jarvis.places")

_SEARCH_URL = "https://places.googleapis.com/v1/places:searchText"
_FIELD_MASK = (
    "places.displayName,places.formattedAddress,places.rating,"
    "places.userRatingCount,places.location,places.googleMapsUri,places.primaryType"
)


def search_places(
    query: str,
    location: str | None = None,
    lat: float | None = None,
    lng: float | None = None,
    limit: int = 5,
) -> dict:
    """Metinle mekan arar. Gerçek isim/puan/adres/koordinat döner (uydurma değil)."""
    if not settings.GOOGLE_PLACES_API_KEY:
        return {"error": "places_unavailable", "message": "Places anahtarı ayarlı değil."}

    text_query = f"{query} {location}".strip() if location else query
    body: dict = {"textQuery": text_query, "languageCode": "tr", "maxResultCount": limit}
    # Konum biliniyorsa "çevremdeki/en yakın" için yakınlık ağırlığı ver.
    if lat is not None and lng is not None:
        body["locationBias"] = {
            "circle": {"center": {"latitude": lat, "longitude": lng}, "radius": 8000.0}
        }

    headers = {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": settings.GOOGLE_PLACES_API_KEY,
        "X-Goog-FieldMask": _FIELD_MASK,
    }
    try:
        resp = httpx.post(_SEARCH_URL, json=body, headers=headers, timeout=15)
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        logger.warning("Places API hatası: %s", exc)
        return {"error": "places_error", "message": "Mekan araması başarısız."}

    places = []
    for p in resp.json().get("places", []):
        loc = p.get("location", {})
        places.append(
            {
                "name": p.get("displayName", {}).get("text"),
                "address": p.get("formattedAddress"),
                "rating": p.get("rating"),
                "rating_count": p.get("userRatingCount"),
                "lat": loc.get("latitude"),
                "lng": loc.get("longitude"),
                "maps_uri": p.get("googleMapsUri"),
            }
        )
    return {"query": text_query, "count": len(places), "places": places}
