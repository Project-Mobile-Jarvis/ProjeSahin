"""Gemini istemcisi + function calling (MANUEL mod).

- google-genai SDK kullanılır.
- Gemini'ye Python callable VERİLMEZ → otomatik function calling (AFC) devrede değil.
- Gemini'nin döndürdüğü function_call ayrıştırılıp {action, args, reply} olarak döner.
- Aksiyonu backend uygulamaz; Flutter uygular (SPEC kuralı).
"""
import logging
import time
from typing import Any

from google import genai
from google.genai import errors as genai_errors
from google.genai import types

from core.config import settings
from tools.definitions import TOOLS

logger = logging.getLogger("jarvis.llm")

# Gemini ara sıra geçici hata döndürür (503 yoğunluk, 429 limit, 500/504 timeout).
# Her modeli bir kez dene; geçici hatada beklemeden YEDEK modele geç (config.model_chain) —
# yoğunlukta aynı modeli retry'lamak yerine farklı modele geçmek daha hızlı/etkili.
_RETRYABLE_CODES = {429, 500, 503, 504}
_ATTEMPTS_PER_MODEL = 1

SYSTEM_INSTRUCTION = (
    "Sen Şahin'sin: Furkan'ın Türkçe sesli kişisel asistanı. "
    "Kısa, net ve samimi (kanka tarzı, ama abartısız) konuşursun. "
    "Kullanıcının isteğini en uygun fonksiyonu çağırarak yerine getir. "
    "Cihaz aksiyonu gerekiyorsa ilgili fonksiyonu çağır (set_alarm, make_call). "
    "Hiçbir aksiyon gerekmiyorsa chat_reply ile cevap ver. "
    "Sesli okunacağı için cevapların KISA olsun (ör: 'Alarm 8'e kuruldu', 'Annenı arıyorum'). "
    "Asla bilgi uydurma."
)

# İstemci ilk kullanımda kurulur (anahtar yoksa Faz 0 import'ları kırılmasın).
_client: genai.Client | None = None


def _get_client() -> genai.Client:
    global _client
    if _client is None:
        if not settings.GEMINI_API_KEY:
            raise RuntimeError("GEMINI_API_KEY ayarlı değil (.env veya Railway env).")
        _client = genai.Client(
            api_key=settings.GEMINI_API_KEY,
            http_options=types.HttpOptions(
                timeout=15000,  # ms — tek çağrı üst sınırı (yavaş modelde asılı kalma, yedeğe geç)
                # SDK iç retry'ı KAPAT (attempts=1): yoğunlukta bizim retry'ımızla çarpışıp
                # gecikmeyi katlıyordu. Dayanıklılık artık hızlı model-zincirinde (_generate).
                retry_options=types.HttpRetryOptions(attempts=1),
            ),
        )
    return _client


def _config() -> types.GenerateContentConfig:
    return types.GenerateContentConfig(
        system_instruction=SYSTEM_INSTRUCTION,
        tools=TOOLS,
        # Python callable verilmediği için AFC zaten tetiklenmez; yine de açıkça kapat.
        automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
        tool_config=types.ToolConfig(
            function_calling_config=types.FunctionCallingConfig(mode="AUTO")
        ),
        # Hız: "thinking"i kapat (budget=0). Sesli asistanda kısa komutlar için gereksiz gecikme.
        thinking_config=types.ThinkingConfig(thinking_budget=settings.GEMINI_THINKING_BUDGET),
    )


def _default_reply(action: str, args: dict[str, Any]) -> str:
    """Gemini function_call ile metin döndürmezse kısa Türkçe onay üret."""
    if action == "set_alarm":
        hour = args.get("hour")
        minute = int(args.get("minute") or 0)
        if hour is None:
            return "Alarm kuruldu."
        return f"Alarm {int(hour):02d}:{minute:02d} olarak kuruldu."
    if action == "make_call":
        target = args.get("target", "")
        return f"{target} aranıyor.".strip()
    if action == "chat_reply":
        return args.get("text", "")
    return "Tamamdır."


def _to_contents(history: list[dict[str, str]], user_message: str) -> list[types.Content]:
    """DB geçmişini + yeni kullanıcı mesajını Gemini contents formatına çevirir."""
    contents: list[types.Content] = []
    for turn in history:
        role = turn.get("role", "user")
        text = turn.get("content") or turn.get("text") or ""
        contents.append(types.Content(role=role, parts=[types.Part(text=text)]))
    contents.append(types.Content(role="user", parts=[types.Part(text=user_message)]))
    return contents


def _generate(client: genai.Client, contents: list[types.Content]):
    """Model zinciri + geçici hata retry'ı ile içerik üretir.

    Her model için _ATTEMPTS_PER_MODEL deneme (kısa backoff). Model geçici hatayla
    (503/429/500) tükenirse sonraki yedek modele geçer. Kalıcı hatada (400/403) hemen yükselir.
    """
    last_exc: Exception | None = None
    for model in settings.model_chain():
        delay = 0.6
        for attempt in range(1, _ATTEMPTS_PER_MODEL + 1):
            try:
                return client.models.generate_content(
                    model=model,
                    contents=contents,
                    config=_config(),
                )
            except genai_errors.APIError as exc:
                last_exc = exc
                if getattr(exc, "code", None) not in _RETRYABLE_CODES:
                    raise  # kalıcı hata — model değiştirmek çözmez
                logger.warning(
                    "Gemini %s geçici hata (code=%s) deneme %d/%d",
                    model, getattr(exc, "code", "?"), attempt, _ATTEMPTS_PER_MODEL,
                )
                if attempt < _ATTEMPTS_PER_MODEL:
                    time.sleep(delay)
                    delay *= 2
        logger.warning("Model %s tükendi, sonraki yedeğe geçiliyor", model)
    raise last_exc  # pragma: no cover (ulaşılmaz)


def run_chat(history: list[dict[str, str]], user_message: str) -> dict[str, Any]:
    """Bir konuşma turu çalıştırır. Döner: {action, args, reply}."""
    client = _get_client()
    contents = _to_contents(history, user_message)

    response = _generate(client, contents)

    candidates = response.candidates or []
    if not candidates or candidates[0].content is None:
        return {"action": "chat_reply", "args": {"text": ""}, "reply": "Anlayamadım, tekrar eder misin?"}

    parts = candidates[0].content.parts or []
    function_call = None
    text_chunks: list[str] = []
    for part in parts:
        if getattr(part, "function_call", None):
            function_call = part.function_call
        elif getattr(part, "text", None):
            text_chunks.append(part.text)
    model_text = " ".join(text_chunks).strip()

    if function_call is not None:
        action = function_call.name
        args = dict(function_call.args) if function_call.args else {}
        if action == "chat_reply":
            reply = args.get("text") or model_text or "Tamam."
        else:
            reply = model_text or _default_reply(action, args)
        return {"action": action, "args": args, "reply": reply}

    # Fonksiyon çağrısı yok → düz sohbet.
    reply = model_text or "Tamam."
    return {"action": "chat_reply", "args": {"text": reply}, "reply": reply}
