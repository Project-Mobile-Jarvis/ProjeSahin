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

    # --- Deepgram STT (Nova-3) — BİRİNCİL. Ayarlıysa Whisper yerine kullanılır.
    # keyterm boost ile isim isabeti (Osman/Valide) Whisper'dan iyi. Hata olursa Whisper'a düşer.
    DEEPGRAM_API_KEY: str = ""
    DEEPGRAM_MODEL: str = "nova-3"

    # --- Groq STT (Faz 2) — Deepgram yoksa/başarısızsa yedek ---
    GROQ_API_KEY: str = ""
    GROQ_STT_MODEL: str = "whisper-large-v3"  # turbo'dan daha doğru (az daha yavaş)

    # --- Google Cloud TTS (Faz 3) ---
    # Servis hesabı: ya GOOGLE_APPLICATION_CREDENTIALS (dosya yolu, yerel),
    # ya da GOOGLE_APPLICATION_CREDENTIALS_JSON (tüm JSON içeriği, Railway → temp dosyaya yazılır).
    GOOGLE_APPLICATION_CREDENTIALS: str = ""
    GOOGLE_APPLICATION_CREDENTIALS_JSON: str = ""
    GOOGLE_TTS_VOICE: str = "tr-TR-Chirp3-HD-Achird"
    GOOGLE_TTS_LANGUAGE: str = "tr-TR"

    # --- Gemini (Faz 1) ---
    GEMINI_API_KEY: str = ""
    # MODEL: gemini-2.5-flash (tüm geçişler). Lite (gemini-2.5-flash-lite) DENENDİ ve BIRAKILDI:
    # konuşma geçmişi birikince fonksiyon çağırmayı bırakıp düz metne kaçıyordu ("anne aranıyor",
    # "annenle konuşmam lazım" → komut hiç çalışmıyordu). Flash, geçmiş varken de güvenilir çağırıyor.
    # Diğer token tasarrufları (prompt/tool kırpma, history 8, web_search terminal) korunuyor;
    # tek-kullanıcı + 10TL limit için Flash maliyeti sorun değil.
    GEMINI_SIMPLE_MODEL: str = "gemini-2.5-flash"   # ilk geçiş
    GEMINI_COMPLEX_MODEL: str = "gemini-2.5-flash"  # escalate: çok-adımlı + düşünme bütçesi
    # web_search grounding alt-çağrısı + yedek zincirin birincili.
    GEMINI_MODEL: str = "gemini-2.5-flash"
    # Birincil model geçici 503/429/504 verirse sırayla denenecek yedekler (virgülle).
    GEMINI_FALLBACK_MODELS: str = "gemini-2.5-flash,gemini-flash-latest,gemini-2.5-flash-lite"
    # Thinking: -1 = modelin varsayılanı (Gemini 3'te çok-adımlı/agentic tool kullanımı için
    # gereken thought_signature'ı üretir — yoksa round-trip'te 400). 0 = kapalı (hızlı ama
    # Gemini 3'te server-tool döngüsünü bozar). Pozitif sayı = sabit düşünme bütçesi.
    GEMINI_THINKING_BUDGET: int = -1
    # Yerleşik google_search grounding. KAPALI tutulur: bu modelde google_search ile
    # function_declarations AYNI istekte 400 veriyor (tüm /chat patlıyor). Web araması
    # bunun yerine web_search SUNUCU tool'u ile yapılır (ayrı, FC'siz grounding alt-çağrısı).
    GEMINI_GROUNDING: bool = False

    # --- Google Places (Faz 4) ---
    GOOGLE_PLACES_API_KEY: str = ""

    def model_chain(self, primary: str | None = None) -> list[str]:
        """Denenecek modeller: birincil + yedekler (tekrarsız, sıralı).
        primary verilirse o kademe (basit/çok-adımlı) öne alınır; yoksa GEMINI_MODEL."""
        chain = [(primary or self.GEMINI_MODEL).strip()]
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
