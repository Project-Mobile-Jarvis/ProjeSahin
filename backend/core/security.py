"""Basit paylaşılan-sır ile endpoint koruması (SPEC 7.3).

Flutter her korunan isteğe `X-API-Key: <API_SHARED_SECRET>` header'ı ekler.
"""
import secrets

from fastapi import Header, HTTPException, status

from core.config import settings


def require_api_key(x_api_key: str = Header(default="", alias="X-API-Key")) -> bool:
    """FastAPI dependency: geçersiz/eksik anahtarda 401 döner."""
    expected = settings.API_SHARED_SECRET
    # secrets.compare_digest: zamanlama saldırısına dayanıklı karşılaştırma
    if not expected or not secrets.compare_digest(x_api_key, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Geçersiz veya eksik X-API-Key",
        )
    return True
