"""Gemini istemcisi + agentic function calling (MANUEL mod, SPEC Faz 1+4).

- google-genai SDK. AFC kapalı; function_call'ları manuel okuruz.
- AGENTIC DÖNGÜ: Gemini bir SUNUCU tool'u çağırırsa (search_places, get_saved_location...)
  backend çalıştırır, sonucu geri besler, Gemini devam eder. CİHAZ tool'u (navigate_to,
  set_alarm...) gelince {action,args,reply} olarak döndürülür (Flutter uygular).
- Model konuşma boyunca SABİTLENİR (Gemini 3 thought_signature tutarlılığı için).
- Web araması: google_search ile function_declarations AYNI istekte 400 verdiği için
  grounding ana döngüye konmaz. Bunun yerine web_search SUNUCU tool'u (tools/websearch.py)
  ayrı, FC'siz bir grounding çağrısı yapar; sonuç döngüye geri beslenir.
"""
import logging
import time
from typing import Any

from google import genai
from google.genai import errors as genai_errors
from google.genai import types

from core.config import settings
from tools.definitions import TOOLS
from tools.registry import SERVER_TOOLS, ToolContext, execute_server_tool

logger = logging.getLogger("jarvis.llm")

# Geçici hatalar: 503 yoğunluk, 429 limit, 500/504 timeout → yedek modele geç.
_RETRYABLE_CODES = {429, 500, 503, 504}
# Agentic döngüde en fazla kaç tur (sonsuz döngü koruması).
_MAX_TOOL_ITERS = 5

SYSTEM_INSTRUCTION = (
    "Sen Şahin'sin: Furkan'ın Türkçe sesli asistanı. Samimi (kanka), sesli okunacak → KISA cevap. "
    "En uygun fonksiyonu çağır:\n"
    "- send_whatsapp: reply'de MUTLAKA onay sor (\"X'e '...' göndereyim mi?\"); 'konumu ekle'→include_location=true.\n"
    "- 'eve/işe götür' → ÖNCE get_saved_location, SONRA navigate_to'ya lat/lng ver. "
    "'en yakın X'e git' → ÖNCE search_places (lat/lng al), SONRA navigate_to'ya o koordinatı ver "
    "(navigate_to'ya belirsiz metin verme).\n"
    "- search_places: ASLA mekan uydurma; en iyi 1-3'ü puanıyla kısaca özetle.\n"
    "- Güncel/genel bilgi (haber, tarih, hava, 'kim/ne/ne zaman') → web_search; ASLA uydurma.\n"
    "- Aksiyon yoksa chat_reply. Asla bilgi uydurma."
)

_client: genai.Client | None = None


def _get_client() -> genai.Client:
    global _client
    if _client is None:
        if not settings.GEMINI_API_KEY:
            raise RuntimeError("GEMINI_API_KEY ayarlı değil (.env veya Railway env).")
        _client = genai.Client(
            api_key=settings.GEMINI_API_KEY,
            http_options=types.HttpOptions(
                timeout=30000,  # ms — agentic döngü + düşünme için biraz daha geniş
                retry_options=types.HttpRetryOptions(attempts=1),  # SDK iç retry kapalı
            ),
        )
    return _client


def _config(use_grounding: bool, thinking_budget: int) -> types.GenerateContentConfig:
    tools = list(TOOLS)
    if use_grounding:
        # google_search ile function_declarations AYRI Tool olmak zorunda.
        tools = tools + [types.Tool(google_search=types.GoogleSearch())]
    # budget < 0 → thinking_config verme (modelin varsayılanı). 0 → düşünme KAPALI (hızlı).
    thinking = (
        types.ThinkingConfig(thinking_budget=thinking_budget) if thinking_budget >= 0 else None
    )
    return types.GenerateContentConfig(
        system_instruction=SYSTEM_INSTRUCTION,
        tools=tools,
        automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
        tool_config=types.ToolConfig(
            function_calling_config=types.FunctionCallingConfig(mode="AUTO")
        ),
        thinking_config=thinking,
    )


def _tool_error_reply(names: list[str]) -> str:
    """Sunucu tool'u hata dönünce kullanıcıya kibar Türkçe mesaj (döngüye GİRMEDEN).

    Hatayı Gemini'ye geri beslersek model 5 tura kadar tekrar dener → 7+ saniye + boşa
    düşünme tokenı. Anahtar yok/geçersizse retry zaten faydasız; hemen kibarca dön.
    """
    if "search_places" in names:
        return "Şu an mekan araması yapamıyorum, birazdan tekrar dener misin?"
    return "Şu an bunu yapamadım kanka, birazdan tekrar dener misin?"


def _default_reply(action: str, args: dict[str, Any]) -> str:
    if action == "set_alarm":
        hour = args.get("hour")
        minute = int(args.get("minute") or 0)
        return f"Alarm {int(hour):02d}:{minute:02d} olarak kuruldu." if hour is not None else "Alarm kuruldu."
    if action == "make_call":
        return f"{args.get('target', '')} aranıyor.".strip()
    if action == "navigate_to":
        return f"{args.get('query', '')} için navigasyon başlatılıyor.".strip()
    if action == "chat_reply":
        return args.get("text", "")
    return "Tamamdır."


def _to_contents(history: list[dict[str, str]], user_message: str) -> list[types.Content]:
    contents: list[types.Content] = []
    for turn in history:
        role = turn.get("role", "user")
        text = turn.get("content") or turn.get("text") or ""
        contents.append(types.Content(role=role, parts=[types.Part(text=text)]))
    contents.append(types.Content(role="user", parts=[types.Part(text=user_message)]))
    return contents


def run_chat(history: list[dict[str, str]], user_message: str, ctx: ToolContext) -> dict[str, Any]:
    """Bir konuşma turu (agentic). Döner: {action, args, reply}."""
    client = _get_client()
    contents = _to_contents(history, user_message)
    escalated_budget = settings.GEMINI_THINKING_BUDGET
    # KADEMELİ MODEL + HIZ: ilk geçiş UCUZ model (SIMPLE) + düşünme KAPALI (budget=0) → basit
    # komut/sohbet hızlı+ucuz. Sunucu-tool ZİNCİRİ (çok-adımlı) tespit edilince YETENEKLİ modele
    # (COMPLEX) yükselt + düşünmeyi aç (Gemini 3 thought_signature için). Model sonra sabitlenir.
    state = {
        "grounding": settings.GEMINI_GROUNDING,
        "model": None,
        "budget": 0,
        "escalated": False,
        "chain": settings.model_chain(settings.GEMINI_SIMPLE_MODEL),
    }

    def _call(model: str):
        """Tek model çağrısı; grounding 429'da grounding'i kapatıp aynı modelle tekrar dener."""
        try:
            return client.models.generate_content(
                model=model, contents=contents, config=_config(state["grounding"], state["budget"])
            )
        except genai_errors.APIError as exc:
            if getattr(exc, "code", None) == 429 and state["grounding"]:
                logger.warning("Grounding 429 — grounding'siz devam ediliyor")
                state["grounding"] = False
                return client.models.generate_content(
                    model=model, contents=contents, config=_config(False, state["budget"])
                )
            raise

    def generate():
        # Sabitli model varsa onu, yoksa zinciri dene. Tüm zincir geçici hata verirse
        # kısa backoff'la 3 tura kadar tekrar dene (Gemini yoğunluk spike'ını aş).
        delay = 1.0
        last_exc: Exception | None = None
        for _round in range(3):
            models = [state["model"]] if state["model"] else state["chain"]
            for model in models:
                try:
                    resp = _call(model)
                    state["model"] = model
                    return resp
                except genai_errors.APIError as exc:
                    last_exc = exc
                    if getattr(exc, "code", None) not in _RETRYABLE_CODES:
                        raise
                    logger.warning("Model %s geçici hata (%s)", model, getattr(exc, "code", "?"))
            time.sleep(delay)
            delay *= 1.8
        raise last_exc  # pragma: no cover

    for _ in range(_MAX_TOOL_ITERS):
        response = generate()
        candidates = response.candidates or []
        if not candidates or candidates[0].content is None:
            return {"action": "chat_reply", "args": {"text": ""},
                    "reply": "Anlayamadım, tekrar eder misin?", "ephemeral": True}

        content = candidates[0].content
        parts = content.parts or []
        fcalls = [p.function_call for p in parts if getattr(p, "function_call", None)]
        model_text = " ".join(p.text for p in parts if getattr(p, "text", None)).strip()

        if not fcalls:
            # İlk-geçiş (Lite) DEGENERE döndüyse (ne fcall ne metin) → boş "Tamam." üretmek
            # yerine yetenekli modele yükselt + bir kez daha dene. Lite, mekan/araştırma
            # sorgularında bazen search_places'i çağırmadan boş dönüyor (tiering tradeoff'u);
            # sadece bu nadir boş durum Flash öder, token tasarrufu korunur.
            if not model_text and not state["escalated"] and escalated_budget != 0:
                state["escalated"] = True
                state["budget"] = escalated_budget
                state["chain"] = settings.model_chain(settings.GEMINI_COMPLEX_MODEL)
                state["model"] = None
                continue
            if model_text:
                return {"action": "chat_reply", "args": {"text": model_text}, "reply": model_text}
            # Boş/degenere → "Tamam." fallback. ephemeral: geçmişe YAZMA (yoksa sonraki
            # komutlar bunu görüp fonksiyon çağırmak yerine chat_reply'a kaçar = çürüme).
            return {"action": "chat_reply", "args": {"text": "Tamam."}, "reply": "Tamam.", "ephemeral": True}

        # Cihaz tool'u varsa onu döndür (Flutter uygular).
        device_call = next((fc for fc in fcalls if fc.name not in SERVER_TOOLS), None)
        if device_call is not None:
            action = device_call.name
            args = dict(device_call.args) if device_call.args else {}
            if action == "chat_reply":
                reply = args.get("text") or model_text or "Tamam."
            else:
                reply = model_text or _default_reply(action, args)
            return {"action": action, "args": args, "reply": reply}

        # web_search TERMİNAL sunucu tool'u: sonucu (zaten Türkçe özet) DOĞRUDAN döndür.
        # Round-trip + düşünme YAPMA — yoksa her web sorgusu 3-4 düşünmeli çağrı eder (pahalı).
        # Burada model turn'ü geri gönderilmediği için thought_signature da gerekmez.
        if fcalls and all(fc.name == "web_search" for fc in fcalls):
            args = dict(fcalls[0].args) if fcalls[0].args else {}
            result = execute_server_tool("web_search", args, ctx)
            reply = (result.get("text") if isinstance(result, dict) else str(result)) or "Bir sonuç bulamadım."
            reply = reply.strip()
            return {"action": "chat_reply", "args": {"text": reply}, "reply": reply}

        # Diğer sunucu tool'ları → ÇOK-ADIMLI zincir → YETENEKLİ modele yükselt + düşünmeyi aç
        # (thought_signature için). İlk kez bu noktaya geldiysek turu COMPLEX model + düşünmeyle yeniden üret.
        if not state["escalated"] and escalated_budget != 0:
            state["escalated"] = True
            state["budget"] = escalated_budget
            state["chain"] = settings.model_chain(settings.GEMINI_COMPLEX_MODEL)  # basit→yetenekli kademe
            state["model"] = None  # yeni kademeden taze model seç
            continue

        # Sunucu tool'larını çalıştır. HEPSİ hata dönerse döngüye GİRME (5 tura kadar
        # tekrar = 7+ saniye + boşa düşünme tokenı); kullanıcıya kibar Türkçe mesajla dön.
        results = [
            (fc.name, execute_server_tool(fc.name, dict(fc.args) if fc.args else {}, ctx))
            for fc in fcalls
        ]
        if results and all(isinstance(r, dict) and r.get("error") for _, r in results):
            reply = _tool_error_reply([n for n, _ in results])
            logger.warning("Sunucu tool'ları hata döndü (%s) → kibar dönüş", [n for n, _ in results])
            return {"action": "chat_reply", "args": {"text": reply}, "reply": reply, "ephemeral": True}

        # Model turn'ünü (thought_signature dahil) aynen ekle, sonuçları geri besle.
        contents.append(content)
        resp_parts = [
            types.Part.from_function_response(name=name, response={"result": r})
            for name, r in results
        ]
        contents.append(types.Content(role="user", parts=resp_parts))

    logger.warning("Agentic döngü sınırı (%d) aşıldı", _MAX_TOOL_ITERS)
    return {"action": "chat_reply", "args": {"text": "Tamam."}, "reply": "Tamam.", "ephemeral": True}
