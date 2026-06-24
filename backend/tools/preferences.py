"""Kalıcı tercihler (key/value) — DB (SPEC 4.1). Sunucu-tarafı tool."""
import logging

from sqlalchemy import select
from sqlalchemy.orm import Session

from db.models import DEFAULT_USER, Preference

logger = logging.getLogger("jarvis.preferences")


def save_preference(db: Session, key: str, value: str, user_id: str = DEFAULT_USER) -> dict:
    key = key.strip().lower()
    row = db.execute(
        select(Preference).where(Preference.user_id == user_id, Preference.key == key)
    ).scalar_one_or_none()
    if row:
        row.value = value
    else:
        db.add(Preference(user_id=user_id, key=key, value=value))
    db.commit()
    return {"ok": True, "key": key, "value": value}


def get_preference(db: Session, key: str, user_id: str = DEFAULT_USER) -> dict:
    key = key.strip().lower()
    row = db.execute(
        select(Preference).where(Preference.user_id == user_id, Preference.key == key)
    ).scalar_one_or_none()
    if not row:
        return {"found": False, "key": key}
    return {"found": True, "key": key, "value": row.value}
