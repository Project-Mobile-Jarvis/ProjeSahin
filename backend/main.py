"""JARVIS backend — FastAPI giriş noktası.

Faz 0: /health (DB ping).
Faz 1: /chat router.
Faz 2: /stt router.
"""
from fastapi import FastAPI, HTTPException
from sqlalchemy import text

from core.config import check_production_config
from db.database import engine
from routers import chat, stt

# Production'da eksik/zayıf sır varsa burada temiz bir hatayla dur (fail-fast).
check_production_config()

app = FastAPI(title="JARVIS Backend", version="0.1.0")

app.include_router(chat.router)
app.include_router(stt.router)


@app.get("/health")
def health() -> dict:
    """Liveness + DB bağlantı kontrolü.

    DB erişilebilir değilse 503 döner — Railway healthcheck'inin instance'ı
    'hazır değil' saymasını sağlar (yanlışlıkla trafik yönlendirilmesin).
    """
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail="db unavailable") from exc
    return {"status": "ok", "db": "ok"}
