"""POST /tts — metin alır, Google Chirp 3 HD ile Türkçe sese (mp3) çevirir (SPEC Faz 3).

Sözleşme:
  İstek:  { "text": "Alarm 8'e kuruldu", "voice": "tr-TR-Chirp3-HD-Charon" (opsiyonel) }
  Cevap:  audio/mpeg (mp3 baytları)
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from core import tts
from core.credentials import google_credentials_available
from core.security import require_api_key

logger = logging.getLogger("jarvis.tts")

router = APIRouter()


class TTSRequest(BaseModel):
    text: str = Field(..., min_length=1, description="Seslendirilecek metin")
    voice: str | None = Field(default=None, description="tr-TR-Chirp3-HD-* (opsiyonel)")


@router.post("/tts", dependencies=[Depends(require_api_key)])
def synthesize(req: TTSRequest) -> Response:
    if not google_credentials_available():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Google TTS kimliği ayarlı değil.",
        )
    try:
        audio = tts.synthesize(req.text, req.voice)
    except Exception as exc:  # Google/ağ hatası → 502 (ham hata sızdırılmaz)
        logger.exception("TTS başarısız")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Ses üretimi başarısız. Lütfen tekrar dene.",
        ) from exc

    return Response(content=audio, media_type="audio/mpeg")
