"""Web araması (SPEC Faz 4) — google_search grounding ile AYRI Gemini alt-çağrısı.

NEDEN ayrı çağrı: bu modelde google_search ile function_declarations AYNI istekte 400
veriyor (tüm /chat patlıyor). Bu yüzden grounding ana agentic döngüye KONMAZ. Gemini
'web_search' SUNUCU tool'unu çağırınca backend burada SADECE grounding'li (FC'siz) bir
Gemini çağrısı yapar, grounded metni döngüye geri besler. İki tool tipi hiç buluşmaz.
"""
import logging

from google import genai
from google.genai import errors as genai_errors
from google.genai import types

from core.config import settings

logger = logging.getLogger("jarvis.websearch")

_RETRYABLE = {429, 500, 503, 504}

_SYSTEM = (
    "Sen Şahin'sin: Furkan'ın samimi Türkçe asistanı. Web'de bulduğun güncel bilgiyi "
    "TEK-İKİ cümleyle, kısa ve samimi (kanka tarzı) söyle — cevap sesli okunacak. "
    "Somut bilgiyi (tarih, sayı, isim) net ver. Bulamazsan kısaca 'bulamadım kanka' de. "
    "ASLA bilgi uydurma."
)

_client: genai.Client | None = None


def _get_client() -> genai.Client:
    global _client
    if _client is None:
        _client = genai.Client(
            api_key=settings.GEMINI_API_KEY,
            http_options=types.HttpOptions(
                timeout=30000,
                retry_options=types.HttpRetryOptions(attempts=1),  # SDK iç retry kapalı
            ),
        )
    return _client


def web_search(query: str) -> dict:
    """google_search grounding ile bilgi araması. {'text': özet} döner."""
    if not query or not query.strip():
        return {"text": "Arama sorgusu boş."}

    client = _get_client()
    config = types.GenerateContentConfig(
        system_instruction=_SYSTEM,
        tools=[types.Tool(google_search=types.GoogleSearch())],  # SADECE grounding, FC YOK
        # Düşünme KAPALI: grounding'e gerek yok, en pahalı kalem (çıktı token'ı) düşer.
        # Burada FC olmadığı için thought_signature derdi yok → 0 güvenli.
        thinking_config=types.ThinkingConfig(thinking_budget=0),
    )
    contents = [types.Content(role="user", parts=[types.Part(text=query)])]

    resp = None
    for model in settings.model_chain():  # 503 yoğunlukta yedeğe geç
        try:
            resp = client.models.generate_content(model=model, contents=contents, config=config)
            break
        except genai_errors.APIError as exc:
            if getattr(exc, "code", None) in _RETRYABLE:
                logger.warning("web_search %s geçici hata (%s)", model, getattr(exc, "code", "?"))
                continue
            logger.warning("web_search hata: %s", exc)
            return {"text": "Web araması şu an yapılamadı."}
    if resp is None:
        return {"text": "Web araması şu an yoğunluktan yapılamadı, sonra dene."}

    cands = resp.candidates or []
    if not cands or cands[0].content is None:
        return {"text": "Bir sonuç bulamadım."}
    parts = cands[0].content.parts or []
    text = " ".join(p.text for p in parts if getattr(p, "text", None)).strip()
    return {"text": text or "Bir sonuç bulamadım."}
