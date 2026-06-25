"""POST /stt — ses dosyası alır, Groq Whisper ile Türkçe metne çevirir (SPEC Faz 2).

Sözleşme:
  İstek:  multipart/form-data, alan adı 'file' = ses (.wav/.m4a/.mp3/...)
  Cevap:  { "text": "saat sekize alarm kur" }
"""
import logging

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status

from core import stt
from core.config import settings
from core.security import require_api_key

logger = logging.getLogger("jarvis.stt")

router = APIRouter()


@router.post("/stt", dependencies=[Depends(require_api_key)])
async def transcribe(file: UploadFile = File(...), keyterms: str = Form("")) -> dict:
    if not settings.DEEPGRAM_API_KEY and not settings.GROQ_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="STT sağlayıcı ayarlı değil (DEEPGRAM_API_KEY veya GROQ_API_KEY).",
        )

    audio = await file.read()
    if not audio:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Boş ses dosyası.",
        )

    try:
        text = stt.transcribe(file.filename or "audio.m4a", audio, keyterms_csv=keyterms)
    except Exception as exc:  # Groq/ağ hatası → 502 (ham hata sızdırılmaz)
        logger.exception("STT başarısız (dosya=%s)", file.filename)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Ses çözümleme başarısız. Lütfen tekrar dene.",
        ) from exc

    return {"text": text}
