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


def transcribe(filename: str, audio: bytes) -> str:
    """Ses baytlarını Türkçe metne çevirir (Groq whisper-large-v3-turbo)."""
    client = _get_client()
    result = client.audio.transcriptions.create(
        file=(filename, audio),
        model=settings.GROQ_STT_MODEL,
        language="tr",
        response_format="json",
    )
    return (result.text or "").strip()
