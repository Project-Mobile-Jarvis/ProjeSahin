"""Ortam değişkenlerinden yapılandırma. Sırlar SADECE env/.env'den okunur (SPEC bölüm 7)."""
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

# backend/.env yolu (CWD ne olursa olsun bulunur)
ENV_PATH = Path(__file__).resolve().parent.parent / ".env"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(ENV_PATH),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- Veritabanı ---
    # Yerel varsayılan docker-compose.yml ile eşleşir. Railway'de DATABASE_URL env'den gelir.
    DATABASE_URL: str = "postgresql+psycopg://jarvis:jarvis_local_dev@localhost:5432/jarvis"

    # --- Backend güvenliği (SPEC 7.3) ---
    # Production'da MUTLAKA güçlü bir değerle ezilir.
    API_SHARED_SECRET: str = "dev-secret-change-me"

    # --- Gemini (Faz 1) ---
    GEMINI_API_KEY: str = ""
    GEMINI_MODEL: str = "gemini-2.5-flash"


settings = Settings()
