"""POST /chat — metin alır, Gemini agentic function calling ile aksiyon JSON döner (SPEC Faz 1+4).

Sözleşme:
  İstek:  { "session_id": "abc", "message": "...", "location": {"lat":.., "lng":..}? }
  Cevap:  { "action": "set_alarm", "args": {...}, "reply": "Alarm 8'e kuruldu" }
location: Flutter anlık GPS'i (opsiyonel) — 'en yakın', 'çevremde', save_location için.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core import llm, memory
from core.config import settings
from core.security import require_api_key
from db.database import get_db
from db.models import DEFAULT_USER
from tools.registry import ToolContext

logger = logging.getLogger("jarvis.chat")

router = APIRouter()


class Location(BaseModel):
    lat: float
    lng: float


class ChatRequest(BaseModel):
    session_id: str = Field(..., min_length=1, description="Konuşma oturumu kimliği")
    message: str = Field(..., min_length=1, description="Kullanıcının metni")
    location: Location | None = Field(default=None, description="Anlık GPS (opsiyonel)")


class ChatResponse(BaseModel):
    action: str
    args: dict
    reply: str


@router.post(
    "/chat",
    response_model=ChatResponse,
    dependencies=[Depends(require_api_key)],
)
def chat(req: ChatRequest, db: Session = Depends(get_db)) -> ChatResponse:
    if not settings.GEMINI_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="GEMINI_API_KEY ayarlı değil.",
        )

    history = memory.load_history(db, req.session_id)
    ctx = ToolContext(
        db=db,
        user_id=DEFAULT_USER,
        lat=req.location.lat if req.location else None,
        lng=req.location.lng if req.location else None,
    )

    try:
        result = llm.run_chat(history, req.message, ctx)
    except Exception as exc:  # Gemini/ağ hatası → 502 (ham hata istemciye sızdırılmaz)
        logger.exception("Gemini çağrısı başarısız (session=%s)", req.session_id)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Gemini isteği başarısız. Lütfen tekrar dene.",
        ) from exc

    # ephemeral: başarısızlık/fallback cevabı ("Tamam.", "Anlayamadım", tool hatası) →
    # ChatResponse şemasında yok, çıkar.
    ephemeral = result.pop("ephemeral", False)

    # Konuşmayı kalıcılaştır (bağlam sonraki turlarda korunsun).
    memory.save_turn(db, req.session_id, "user", req.message)
    # Geçmişe SADECE gerçek sohbet (chat_reply, ephemeral değil) cevabını yaz. AKSİYON turları
    # (make_call/navigate_to/set_alarm) ve BAŞARISIZLIK fallback'leri geçmişi zehirliyor: model
    # bir sonraki sefer fonksiyon çağırmak yerine o metni ("anne aranıyor.", "Tamam.") tekrar
    # üretip komutu çalıştırmıyordu (function-call düz metne dönüşüp "doğru cevap bu" sanılıyor).
    if result["action"] == "chat_reply" and not ephemeral:
        memory.save_turn(db, req.session_id, "model", result["reply"])

    return ChatResponse(**result)
