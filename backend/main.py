"""JARVIS backend — FastAPI giriş noktası.

Faz 0: /health (DB ping dahil).
Faz 1: /chat router eklenir.
"""
from fastapi import FastAPI
from sqlalchemy import text

from db.database import engine
from routers import chat

app = FastAPI(title="JARVIS Backend", version="0.1.0")

app.include_router(chat.router)


@app.get("/health")
def health() -> dict:
    """Liveness + DB bağlantı kontrolü. Her zaman 200 döner; 'db' alanı durumu gösterir."""
    db_status = "ok"
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception:
        db_status = "error"
    return {"status": "ok" if db_status == "ok" else "degraded", "db": db_status}
