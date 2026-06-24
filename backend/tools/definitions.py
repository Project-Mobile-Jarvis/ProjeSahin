"""Gemini function calling araç tanımları (SPEC bölüm 4).

Faz 1 kapsamı: set_alarm, make_call, chat_reply.
Sonraki fazlarda buraya: send_sms, send_whatsapp, search_places, navigate_to,
open_app, save_location, get_saved_location, save_preference, get_preference eklenecek.

NOT: Bunlar sadece TANIM. Backend fonksiyonu ÇALIŞTIRMAZ — Gemini'nin döndürdüğü
function_call (ad + argüman) JSON olarak Flutter'a iletilir, aksiyonu cihaz uygular.
"""
from google.genai import types

_OBJ = types.Type.OBJECT
_STR = types.Type.STRING
_INT = types.Type.INTEGER


def _str(desc: str) -> types.Schema:
    return types.Schema(type=_STR, description=desc)


def _int(desc: str) -> types.Schema:
    return types.Schema(type=_INT, description=desc)


SET_ALARM = types.FunctionDeclaration(
    name="set_alarm",
    description="Telefonda belirtilen saate alarm kurar. Kullanıcı 'saat 8'e alarm kur' gibi dediğinde.",
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "hour": _int("Saat, 24 saat formatı (0-23)."),
            "minute": _int("Dakika (0-59). Belirtilmediyse 0."),
            "label": _str("Alarm etiketi. Belirtilmediyse 'Alarm'."),
        },
        required=["hour"],
    ),
)

MAKE_CALL = types.FunctionDeclaration(
    name="make_call",
    description="Bir kişiyi telefondan arar. Hedef kişi cihazda rehberden çözülür ('annemi ara', 'Sevdem'i ara').",
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "target": _str("Aranacak kişi, kullanıcının söylediği şekilde. Ör: 'anne', 'Sevdem'."),
        },
        required=["target"],
    ),
)

CHAT_REPLY = types.FunctionDeclaration(
    name="chat_reply",
    description=(
        "Hiçbir cihaz aksiyonu gerektirmeyen durumlarda kullan: selamlaşma, soru-cevap, "
        "sohbet. Kullanıcıya söylenecek kısa, samimi Türkçe metni döndür."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "text": _str("Kullanıcıya söylenecek kısa, samimi Türkçe cevap."),
        },
        required=["text"],
    ),
)

# Gemini'ye verilecek tek Tool (tüm fonksiyon tanımları).
TOOLS = [
    types.Tool(
        function_declarations=[SET_ALARM, MAKE_CALL, CHAT_REPLY],
    )
]
