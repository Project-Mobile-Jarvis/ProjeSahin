"""Sunucu-tarafı tool yönlendiricisi (SPEC Faz 4).

Sunucu tool'ları: backend çalıştırır, sonucu Gemini'ye geri besler (agentic döngü).
Cihaz tool'ları: Flutter'a aksiyon JSON olarak döner.
"""
import logging
from dataclasses import dataclass
from typing import Any

from sqlalchemy.orm import Session

from tools import locations, places, preferences

logger = logging.getLogger("jarvis.tools")

# Backend'in çalıştırıp sonucunu Gemini'ye geri beslediği tool'lar.
SERVER_TOOLS = {
    "search_places",
    "save_location",
    "get_saved_location",
    "save_preference",
    "get_preference",
}


@dataclass
class ToolContext:
    """Sunucu tool'larının ihtiyaç duyduğu istek bağlamı."""

    db: Session
    user_id: str
    lat: float | None = None
    lng: float | None = None


def execute_server_tool(name: str, args: dict[str, Any], ctx: ToolContext) -> dict:
    """Bir sunucu-tarafı tool'u çalıştırır ve Gemini'ye dönecek sonucu üretir."""
    try:
        if name == "search_places":
            return places.search_places(
                query=args.get("query", ""),
                location=args.get("location"),
                lat=ctx.lat,
                lng=ctx.lng,
            )
        if name == "save_location":
            return locations.save_location(
                ctx.db, args.get("label", ""), ctx.lat, ctx.lng, ctx.user_id
            )
        if name == "get_saved_location":
            return locations.get_saved_location(ctx.db, args.get("label", ""), ctx.user_id)
        if name == "save_preference":
            return preferences.save_preference(
                ctx.db, args.get("key", ""), args.get("value", ""), ctx.user_id
            )
        if name == "get_preference":
            return preferences.get_preference(ctx.db, args.get("key", ""), ctx.user_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Sunucu tool hatası: %s", name)
        return {"error": "tool_error", "message": str(exc)[:120]}
    return {"error": "unknown_tool", "name": name}
