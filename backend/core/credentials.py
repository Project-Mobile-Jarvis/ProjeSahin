"""Google servis hesabı kimliğini ortamdan hazırla (SPEC 7.1).

Railway'de JSON dosya yükleyemeyiz → tüm JSON içeriği GOOGLE_APPLICATION_CREDENTIALS_JSON
env'inde gelir; burada güvenli bir geçici dosyaya yazıp GOOGLE_APPLICATION_CREDENTIALS'a
işaret ederiz. Yerelde doğrudan GOOGLE_APPLICATION_CREDENTIALS (dosya yolu) da kullanılabilir.
"""
import logging
import os
import tempfile

from core.config import settings

logger = logging.getLogger("jarvis.credentials")

_prepared = False


def ensure_google_credentials() -> None:
    """GOOGLE_APPLICATION_CREDENTIALS_JSON varsa temp dosyaya yazıp env'i ayarlar (bir kez)."""
    global _prepared
    if _prepared:
        return

    raw = settings.GOOGLE_APPLICATION_CREDENTIALS_JSON.strip()
    if raw:
        fd, path = tempfile.mkstemp(prefix="gcp-tts-", suffix=".json")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(raw)
        try:
            os.chmod(path, 0o600)  # sadece sahip okuyabilsin
        except OSError:
            pass
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = path
        logger.info("Google credentials JSON env'den geçici dosyaya yazıldı.")
    elif settings.GOOGLE_APPLICATION_CREDENTIALS:
        # .env'den gelen dosya yolunu os.environ'a köprüle (Google kütüphanesi oradan okur).
        os.environ.setdefault(
            "GOOGLE_APPLICATION_CREDENTIALS", settings.GOOGLE_APPLICATION_CREDENTIALS
        )

    _prepared = True


def google_credentials_available() -> bool:
    """TTS için kullanılabilir bir kimlik var mı? (JSON içeriği veya dosya yolu)"""
    return bool(
        settings.GOOGLE_APPLICATION_CREDENTIALS_JSON.strip()
        or settings.GOOGLE_APPLICATION_CREDENTIALS
        or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    )
