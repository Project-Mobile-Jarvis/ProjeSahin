"""POST /stt — ses dosyası alır, Groq Whisper ile Türkçe metne çevirir (SPEC Faz 2).

Sözleşme:
  İstek:  multipart/form-data, alan adı 'file' = ses (.wav/.m4a/.mp3/...)
  Cevap:  { "text": "saat sekize alarm kur" }
"""
import logging

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status

from core import stt
from core.config import settings
from core.security import require_api_key

logger = logging.getLogger("jarvis.stt")

router = APIRouter()


@router.post("/stt", dependencies=[Depends(require_api_key)])
async def transcribe(file: UploadFile = File(...)) -> dict:
    if not settings.GROQ_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="GROQ_API_KEY ayarlı değil.",
        )

    audio = await file.read()
    if not audio:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Boş ses dosyası.",
        )

    try:
        text = stt.transcribe(file.filename or "audio.wav", audio)
    except Exception as exc:  # Groq/ağ hatası → 502 (ham hata sızdırılmaz)
        logger.exception("STT başarısız (dosya=%s)", file.filename)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Ses çözümleme başarısız. Lütfen tekrar dene.",
        ) from exc

    return {"text": text}
