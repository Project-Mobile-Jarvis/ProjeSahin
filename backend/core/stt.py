"""Ses→metin (SPEC Faz 2).

Birincil: Deepgram Nova-3 — keyterm boost ile isim/komut isabeti (Osman, Valide...).
DEEPGRAM_API_KEY yoksa VEYA Deepgram hata verirse Groq Whisper'a düşer (güvenli yedek).
"""
import logging

import httpx
from groq import Groq

from core.config import settings

logger = logging.getLogger("jarvis.stt")

_groq: Groq | None = None
_DEEPGRAM_URL = "https://api.deepgram.com/v1/listen"


def _get_groq() -> Groq:
    global _groq
    if _groq is None:
        if not settings.GROQ_API_KEY:
            raise RuntimeError("GROQ_API_KEY ayarlı değil.")
        _groq = Groq(api_key=settings.GROQ_API_KEY)
    return _groq


def _content_type(filename: str) -> str:
    f = filename.lower()
    if f.endswith(".wav"):
        return "audio/wav"
    if f.endswith(".mp3"):
        return "audio/mpeg"
    return "audio/mp4"  # m4a/mp4/aac (uygulamanın kaydı m4a/AAC)


def _deepgram(filename: str, audio: bytes, keyterms: list[str]) -> str:
    """Deepgram Nova-3 transkripsiyon. keyterm → isim/komut zorlaması (boost)."""
    params: list[tuple[str, str]] = [
        ("model", settings.DEEPGRAM_MODEL),
        ("language", "tr"),
        ("smart_format", "true"),
    ]
    for kt in keyterms[:90]:  # Deepgram keyterm üst sınırı ~100
        params.append(("keyterm", kt))
    headers = {
        "Authorization": f"Token {settings.DEEPGRAM_API_KEY}",
        "Content-Type": _content_type(filename),
    }
    resp = httpx.post(_DEEPGRAM_URL, params=params, headers=headers, content=audio, timeout=30.0)
    resp.raise_for_status()
    alts = resp.json()["results"]["channels"][0]["alternatives"]
    return (alts[0]["transcript"] if alts else "").strip()


def _whisper(filename: str, audio: bytes, prompt: str) -> str:
    """Groq Whisper (yedek). prompt → önyargı (Deepgram'a göre zayıf)."""
    client = _get_groq()
    kwargs = {
        "file": (filename, audio),
        "model": settings.GROQ_STT_MODEL,
        "language": "tr",
        "temperature": 0,
        "response_format": "json",
    }
    if prompt and prompt.strip():
        kwargs["prompt"] = prompt.strip()[:900]
    result = client.audio.transcriptions.create(**kwargs)
    return (result.text or "").strip()


def transcribe(filename: str, audio: bytes, keyterms_csv: str = "") -> str:
    """Ses baytlarını Türkçe metne çevirir. keyterms_csv: virgüllü isim/komut listesi (boost)."""
    terms = [t.strip() for t in keyterms_csv.split(",") if t.strip()]
    if settings.DEEPGRAM_API_KEY:
        try:
            return _deepgram(filename, audio, terms)
        except Exception:
            logger.exception("Deepgram başarısız — Whisper yedeğine düşülüyor")
    return _whisper(filename, audio, ", ".join(terms))
