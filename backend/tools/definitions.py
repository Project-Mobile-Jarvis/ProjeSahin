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

# ---- Faz 4: araştırma / mekan / navigasyon / kişisel hafıza ----

SEARCH_PLACES = types.FunctionDeclaration(
    name="search_places",
    description=(
        "Gerçek mekan/işletme arar (restoran, benzin istasyonu, kafe, eczane vb.) ve "
        "isim/puan/adres/konum döner. 'çevremde iyi restoran', 'Bodrum'da kahvaltı', "
        "'en yakın benzinci' gibi durumlarda kullan. SUNUCU çalıştırır."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "query": _str("Aranan tür/şey: 'restoran', 'benzin istasyonu', 'kahvaltı' vb."),
            "location": _str("Şehir/semt. Belirtilmezse kullanıcının çevresi kullanılır."),
        },
        required=["query"],
    ),
)

WEB_SEARCH = types.FunctionDeclaration(
    name="web_search",
    description=(
        "Güncel veya genel bilgi için web'de arama yapar: haberler, tarihler, akademik takvim, "
        "hava durumu, fiyatlar, 'kim/ne/ne zaman/nerede' soruları, bilmediğin güncel olgular. "
        "Cihaz aksiyonu olmayan ama doğru/güncel bilgi gerektiren her soruda kullan. "
        "Kendi bilgini uydurma — emin değilsen bunu çağır. SUNUCU çalıştırır."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "query": _str("Web'de aranacak net sorgu, ör: '2025-2026 Muğla Sıtkı Koçman akademik takvim'."),
        },
        required=["query"],
    ),
)

NAVIGATE_TO = types.FunctionDeclaration(
    name="navigate_to",
    description=(
        "Araçla navigasyonu BAŞLATIR; telefonda Google Haritalar yol tarifi modunda açılır. "
        "'eve götür', 'işe git', restoran adı, 'en yakın benzinciye git' gibi. Koordinat "
        "biliniyorsa (get_saved_location veya search_places'ten) lat/lng ver; yoksa query yeter."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "query": _str("Gidilecek yerin adı/tarifi: 'ev', 'iş', restoran adı, 'en yakın benzinci'."),
            "lat": types.Schema(type=types.Type.NUMBER, description="Hedef enlem (biliniyorsa)."),
            "lng": types.Schema(type=types.Type.NUMBER, description="Hedef boylam (biliniyorsa)."),
        },
        required=["query"],
    ),
)

SAVE_LOCATION = types.FunctionDeclaration(
    name="save_location",
    description=(
        "Kullanıcının ANLIK konumunu bir etiketle kalıcı kaydeder. 'şu anki konumumu evim "
        "olarak kaydet', 'burayı iş yap'. Koordinat telefonun GPS'inden gelir. SUNUCU çalıştırır."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={"label": _str("Etiket: 'ev', 'iş', 'spor salonu' vb.")},
        required=["label"],
    ),
)

GET_SAVED_LOCATION = types.FunctionDeclaration(
    name="get_saved_location",
    description=(
        "Daha önce kaydedilmiş konumu (ev/iş vb.) getirir. 'eve götür' (navigate_to'dan önce) "
        "veya 'evim nerede' için. SUNUCU çalıştırır."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={"label": _str("Etiket: 'ev', 'iş' vb.")},
        required=["label"],
    ),
)

SAVE_PREFERENCE = types.FunctionDeclaration(
    name="save_preference",
    description=(
        "Kalıcı kişisel tercih kaydeder. 'en sevdiğim mutfak İtalyan', 'sabah 7'de uyan' gibi. "
        "SUNUCU çalıştırır."
    ),
    parameters=types.Schema(
        type=_OBJ,
        properties={
            "key": _str("Tercih anahtarı, ör: 'favori_mutfak'."),
            "value": _str("Tercih değeri, ör: 'İtalyan'."),
        },
        required=["key", "value"],
    ),
)

GET_PREFERENCE = types.FunctionDeclaration(
    name="get_preference",
    description="Kayıtlı tercihi getirir. SUNUCU çalıştırır.",
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
