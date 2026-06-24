"""Gemini istemcisi + function calling (MANUEL mod).

- google-genai SDK kullanılır.
- Gemini'ye Python callable VERİLMEZ → otomatik function calling (AFC) devrede değil.
- Gemini'nin döndürdüğü function_call ayrıştırılıp {action, args, reply} olarak döner.
- Aksiyonu backend uygulamaz; Flutter uygular (SPEC kuralı).
"""
from typing import Any

from google import genai
from google.genai import types

from core.config import settings
from tools.definitions import TOOLS

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
        _client = genai.Client(api_key=settings.GEMINI_API_KEY)
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


def run_chat(history: list[dict[str, str]], user_message: str) -> dict[str, Any]:
    """Bir konuşma turu çalıştırır. Döner: {action, args, reply}."""
    client = _get_client()
    contents = _to_contents(history, user_message)

    response = client.models.generate_content(
        model=settings.GEMINI_MODEL,
        contents=contents,
        config=_config(),
    )

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
