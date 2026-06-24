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

    # --- Groq STT (Faz 2) ---
    GROQ_API_KEY: str = ""
    GROQ_STT_MODEL: str = "whisper-large-v3-turbo"

    # --- Google Cloud TTS (Faz 3) ---
    # Servis hesabı: ya GOOGLE_APPLICATION_CREDENTIALS (dosya yolu, yerel),
    # ya da GOOGLE_APPLICATION_CREDENTIALS_JSON (tüm JSON içeriği, Railway → temp dosyaya yazılır).
    GOOGLE_APPLICATION_CREDENTIALS: str = ""
    GOOGLE_APPLICATION_CREDENTIALS_JSON: str = ""
    GOOGLE_TTS_VOICE: str = "tr-TR-Chirp3-HD-Achird"
    GOOGLE_TTS_LANGUAGE: str = "tr-TR"

    # --- Gemini (Faz 1) ---
    GEMINI_API_KEY: str = ""
    # Birincil model. "gemini-flash-latest" Google'ın güncel en iyi flash'ini takip eden
    # stabil alias — hız/performans dengesi en iyi, sürüm çıktıkça otomatik güncellenir.
    GEMINI_MODEL: str = "gemini-flash-latest"
    # Birincil model geçici 503/429/504 verirse sırayla denenecek yedekler (virgülle).
    GEMINI_FALLBACK_MODELS: str = "gemini-2.5-flash,gemini-2.5-flash-lite,gemini-3-flash-preview"
    # Thinking: -1 = modelin varsayılanı (Gemini 3'te çok-adımlı/agentic tool kullanımı için
    # gereken thought_signature'ı üretir — yoksa round-trip'te 400). 0 = kapalı (hızlı ama
    # Gemini 3'te server-tool döngüsünü bozar). Pozitif sayı = sabit düşünme bütçesi.
    GEMINI_THINKING_BUDGET: int = -1
    # Yerleşik google_search grounding (web araması). 429 kotada zarifçe grounding'siz devam eder.
    GEMINI_GROUNDING: bool = True

    # --- Google Places (Faz 4) ---
    GOOGLE_PLACES_API_KEY: str = ""

    def model_chain(self) -> list[str]:
        """Denenecek modeller: birincil + yedekler (tekrarsız, sıralı)."""
        chain = [self.GEMINI_MODEL.strip()]
        for m in self.GEMINI_FALLBACK_MODELS.split(","):
            m = m.strip()
            if m and m not in chain:
                chain.append(m)
        return chain

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
