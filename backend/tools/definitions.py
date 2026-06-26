"""Gemini function calling araç tanımları (SPEC bölüm 4).

Açıklamalar KISA tutulur (token tasarrufu) — yönlendirme kuralları sistem promptunda.
NOT: Bunlar sadece TANIM. Backend cihaz fonksiyonunu ÇALIŞTIRMAZ — Gemini'nin döndürdüğü
function_call (ad + argüman) JSON olarak Flutter'a iletilir, aksiyonu cihaz uygular.
SUNUCU tool'larını (search_places, locations, preferences) backend çalıştırır.
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
    description="Saate alarm kurar ('saat 8'e alarm').",
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "hour": _int("Saat (0-23)."),
            "minute": _int("Dakika (0-59). Yoksa 0."),
            "label": _str("Etiket. Yoksa 'Alarm'."),
        },
        required=["hour"],
    ),
)

MAKE_CALL = types.FunctionDeclaration(
    name="make_call",
    description="Kişiyi arar; rehberden çözülür ('annemi ara').",
    parameters=types.Schema(
        type=_OBJ,
        properties={"target": _str("Aranacak kişi, ör: 'anne', 'Sevdem'.")},
        required=["target"],
    ),
)

SEND_WHATSAPP = types.FunctionDeclaration(
    name="send_whatsapp",
    description=(
        "WhatsApp mesajı gönderir ('anneme ... yaz'). Kişi rehberden çözülür. "
        "reply'de MUTLAKA onay sorusu sor; gönderme onaydan sonra cihazda olur."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "target": _str("Kişi, ör: 'anne', 'Sevdem'."),
            "text": _str("Gönderilecek kısa Türkçe mesaj."),
            "include_location": types.Schema(
                type=types.Type.BOOLEAN, description="Mesaja konum (Maps linki) eklensin mi. Varsayılan false."
            ),
            "location_query": _str("Konum eklenecekse yer; boşsa anlık konum."),
        },
        required=["target", "text"],
    ),
)

CHAT_REPLY = types.FunctionDeclaration(
    name="chat_reply",
    description="Cihaz aksiyonu gerekmeyen durumlar (selam, sohbet, soru-cevap): kısa samimi Türkçe cevap.",
    parameters=types.Schema(
        type=_OBJ,
        properties={"text": _str("Kullanıcıya kısa Türkçe cevap.")},
        required=["text"],
    ),
)

# ---- Faz 4: araştırma / mekan / navigasyon / kişisel hafıza ----

SEARCH_PLACES = types.FunctionDeclaration(
    name="search_places",
    description="Gerçek mekan/işletme arar (restoran, benzinci, kafe...) isim/puan/adres/konum döner. ASLA uydurma. SUNUCU.",
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "query": _str("Tür/şey: 'restoran', 'benzin istasyonu'."),
            "location": _str("Şehir/semt. Yoksa kullanıcının çevresi."),
        },
        required=["query"],
    ),
)

WEB_SEARCH = types.FunctionDeclaration(
    name="web_search",
    description="Güncel/genel bilgi için web araması (haber, tarih, hava, fiyat, 'kim/ne/ne zaman'). Uydurma; emin değilsen çağır. SUNUCU.",
    parameters=types.Schema(
        type=_OBJ,
        properties={"query": _str("Net sorgu, ör: '2025-2026 Muğla Sıtkı Koçman akademik takvim'.")},
        required=["query"],
    ),
)

NAVIGATE_TO = types.FunctionDeclaration(
    name="navigate_to",
    description=(
        "Araçla navigasyonu başlatır (Google Haritalar). 'eve götür', restoran adı, 'en yakın benzinci'. "
        "Koordinat biliniyorsa lat/lng ver, yoksa query."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "query": _str("Gidilecek yer: 'ev', restoran adı, 'en yakın benzinci'."),
            "lat": types.Schema(type=types.Type.NUMBER, description="Hedef enlem (biliniyorsa)."),
            "lng": types.Schema(type=types.Type.NUMBER, description="Hedef boylam (biliniyorsa)."),
        },
        required=["query"],
    ),
)

SAVE_LOCATION = types.FunctionDeclaration(
    name="save_location",
    description="Anlık konumu etiketle kaydeder ('burayı ev yap'). Koordinat GPS'ten. SUNUCU.",
    parameters=types.Schema(
        type=_OBJ,
        properties={"label": _str("Etiket: 'ev', 'iş' vb.")},
        required=["label"],
    ),
)

GET_SAVED_LOCATION = types.FunctionDeclaration(
    name="get_saved_location",
    description="Kayıtlı konumu getirir (ev/iş). 'eve götür'den önce. SUNUCU.",
    parameters=types.Schema(
        type=_OBJ,
        properties={"label": _str("Etiket: 'ev', 'iş' vb.")},
        required=["label"],
    ),
)

SAVE_PREFERENCE = types.FunctionDeclaration(
    name="save_preference",
    description="Kişisel tercih kaydeder ('favori mutfak İtalyan'). SUNUCU.",
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "key": _str("Anahtar, ör: 'favori_mutfak'."),
            "value": _str("Değer, ör: 'İtalyan'."),
        },
        required=["key", "value"],
    ),
)

GET_PREFERENCE = types.FunctionDeclaration(
    name="get_preference",
    description="Kayıtlı tercihi getirir. SUNUCU.",
    parameters=types.Schema(
        type=_OBJ,
        properties={"key": _str("Tercih anahtarı.")},
        required=["key"],
    ),
)

# Gemini'ye verilecek fonksiyon tanımları (tek Tool).
_FUNCTIONS = [
    SET_ALARM,
    MAKE_CALL,
    SEND_WHATSAPP,
    CHAT_REPLY,
    SEARCH_PLACES,
    WEB_SEARCH,
    NAVIGATE_TO,
    SAVE_LOCATION,
    GET_SAVED_LOCATION,
    SAVE_PREFERENCE,
    GET_PREFERENCE,
]

TOOLS = [types.Tool(function_declarations=_FUNCTIONS)]
