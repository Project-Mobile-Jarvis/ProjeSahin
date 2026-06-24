"""Ortam değişkenlerinden yapılandırma. Sırlar SADECE env/.env'den okunur (SPEC bölüm 7)."""
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# backend/.env yolu (CWD ne olursa olsun bulunur)
ENV_PATH = Path(__file__).resolve().parent.parent / ".env"

_DEFAULT_SECRET = "dev-secret-change-me"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(ENV_PATH),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # development | production. Railway'de "production" yapılır → sır doğrulaması devreye girer.
    ENVIRONMENT: str = "development"

    # --- Veritabanı ---
    # Yerel varsayılan docker-compose / portable Postgres ile eşleşir.
    # Railway DATABASE_URL'i "postgresql://..." formatında verir → aşağıda +psycopg'ye normalize edilir.
    DATABASE_URL: str = "postgresql+psycopg://jarvis:jarvis_local_dev@localhost:5432/jarvis"

    # --- Backend güvenliği (SPEC 7.3) ---
    API_SHARED_SECRET: str = _DEFAULT_SECRET

    # --- Gemini (Faz 1) ---
    GEMINI_API_KEY: str = ""
    GEMINI_MODEL: str = "gemini-2.5-flash"

    @field_validator("DATABASE_URL")
    @classmethod
    def _normalize_db_url(cls, v: str) -> str:
        """psycopg v3 kullanıyoruz; sürücüsüz 'postgresql://' SQLAlchemy'de psycopg2 demek (kurulu değil).
        Railway'in verdiği çıplak URL'i +psycopg'ye çevir."""
        if v.startswith("postgresql+"):
            return v  # sürücü zaten belirtilmiş
        if v.startswith("postgresql://"):
            return "postgresql+psycopg://" + v[len("postgresql://"):]
        if v.startswith("postgres://"):  # bazı sağlayıcıların eski formatı
            return "postgresql+psycopg://" + v[len("postgres://"):]
        return v


settings = Settings()


def check_production_config() -> None:
    """Production'da zayıf/eksik sırlarla ayağa kalkmayı engelle (fail-fast).

    Pydantic validator İÇİNDE değil — orada hata, tüm ayar değerlerini (sırlar dahil)
    traceback'e döker. Burada SADECE eksik değişken İSİMLERİ raporlanır.
    main.py başlangıçta çağırır.
    """
    if settings.ENVIRONMENT.lower() != "production":
        return
    missing = []
    if not settings.API_SHARED_SECRET or settings.API_SHARED_SECRET == _DEFAULT_SECRET:
        missing.append("API_SHARED_SECRET")
    if not settings.GEMINI_API_KEY:
        missing.append("GEMINI_API_KEY")
    if missing:
        raise RuntimeError(
            "Production'da şu ortam değişkenleri ayarlanmalı (güçlü değerlerle): "
            + ", ".join(missing)
        )
