"""Kalıcı kişisel konumlar (ev, iş, ...) — DB (SPEC 4.1). Sunucu-tarafı tool.

NOT: save_location'ın koordinatları telefonun GPS'inden gelir (Flutter). Backend bu
koordinatları /chat isteğindeki 'location' alanından (ToolContext) alır.
"""
import logging

from sqlalchemy import select
from sqlalchemy.orm import Session

from db.models import DEFAULT_USER, SavedLocation

logger = logging.getLogger("jarvis.locations")


def save_location(
    db: Session, label: str, lat: float | None, lng: float | None, user_id: str = DEFAULT_USER
) -> dict:
    """Bir etiketi (ev/iş) anlık koordinatla kaydeder/günceller."""
    if lat is None or lng is None:
        return {"ok": False, "message": "Konum bilgisi yok (GPS gerekli)."}
    label = label.strip().lower()
    row = db.execute(
        select(SavedLocation).where(
            SavedLocation.user_id == user_id, SavedLocation.label == label
        )
    ).scalar_one_or_none()
    if row:
        row.lat, row.lng = lat, lng
    else:
        db.add(SavedLocation(user_id=user_id, label=label, lat=lat, lng=lng))
    db.commit()
    return {"ok": True, "label": label, "lat": lat, "lng": lng}


def get_saved_location(db: Session, label: str, user_id: str = DEFAULT_USER) -> dict:
    """Etikete göre kayıtlı konumu döner."""
    label = label.strip().lower()
    row = db.execute(
        select(SavedLocation).where(
            SavedLocation.user_id == user_id, SavedLocation.label == label
        )
    ).scalar_one_or_none()
    if not row:
        return {"found": False, "label": label}
    return {"found": True, "label": label, "lat": row.lat, "lng": row.lng}
