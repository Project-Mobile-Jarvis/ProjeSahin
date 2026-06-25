"""Groq Whisper ile ses→metin (SPEC Faz 2). ONLINE STT."""
import logging

from groq import Groq

from core.config import settings

logger = logging.getLogger("jarvis.stt")

_client: Groq | None = None


def _get_client() -> Groq:
    global _client
    if _client is None:
        if not settings.GROQ_API_KEY:
            raise RuntimeError("GROQ_API_KEY ayarlı değil (.env veya Railway env).")
        _client = Groq(api_key=settings.GROQ_API_KEY)
    return _client


def transcribe(filename: str, audio: bytes, prompt: str = "") -> str:
    """Ses baytlarını Türkçe metne çevirir (Groq Whisper).

    prompt: tanımayı yönlendiren önyargı metni (kişi adları + komut kelimeleri).
    Whisper bunu bağlam olarak kullanır → 'Osman', 'Valide', 'peder' gibi isimleri/kelimeleri
    doğru yazma olasılığı ciddi artar. temperature=0 → en olası (uydurmasız) çıktı.
    """
    client = _get_client()
    kwargs = {
        "file": (filename, audio),
        "model": settings.GROQ_STT_MODEL,
        "language": "tr",
        "temperature": 0,
        "response_format": "json",
    }
    if prompt and prompt.strip():
        kwargs["prompt"] = prompt.strip()[:900]  # Whisper prompt ~224 token; makul sınır
    result = client.audio.transcriptions.create(**kwargs)
    return (result.text or "").strip()
