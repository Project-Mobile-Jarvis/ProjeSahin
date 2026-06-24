# JARVIS — Türkçe Sesli Asistan · Proje Spesifikasyonu (SPEC)

> **Bu dosya ne işe yarar:** Bu, Claude Code'a verilecek eksiksiz proje brief'idir. Kendi kendine yeterlidir — Claude Code bu dosyayı okuyup projeyi sıfırdan kurabilir. Dosya, ilgili tüm bileşenleri, dosya/arayüz isimlerini, kapsam dışını ve her faz için doğrulama adımlarını içerir.
>
> **Nasıl kullanılır:** Claude Code best practice'lerine göre (Anthropic resmi dokümanı), bu spec'i repoya koy, `CLAUDE.md`'yi (bölüm 11'deki şablon) oluştur, sonra her fazı ayrı oturumda çalıştır. Detaylı kullanım bölüm 12'de.

---

## 0. Bir Cümlede Proje

Türkçe konuşan, telefonda gerçek aksiyon alan (arama, alarm, WhatsApp, navigasyon, web araştırması), internet varken bulut zekâsıyla (Gemini) akıllı çalışan, internet yokken cihaz üstünde temel komutları offline çözen, "Jarvis/Siri benzeri" kişisel sesli asistan — **Flutter (Android)** mobil uygulama + **FastAPI (Railway)** backend mimarisiyle.

---

## 1. Uygulamanın Detaylı Açıklaması

### 1.1 Ne yapıyor?

Kullanıcı (Furkan) telefonuna bir wake word ("Şahin") söyleyerek asistanı uyandırır, sonra Türkçe konuşur. Asistan:

- **Basit cihaz komutlarını** yerine getirir: "annemi ara", "saat 8'e alarm kur", "el fenerini aç", "Spotify'ı aç"
- **Akıllı, çok adımlı sohbet** yürütür: "Sevdem'le Bodrum'da yemek yiyeceğim, iyi restoran öner" → araştırır, yorumları okur, önerir → "o iyiymiş, 8'de mesaj at" → WhatsApp mesajı kurar → "konumu da ekle" → Maps linki ekler → "gönder" → gönderir
- **Gerçekten internette araştırma** yapar: web'de arar, sayfaları açıp yorumları okur (agentic LLM mantığı), Google Places'ten gerçek mekan verisi çeker
- **Navigasyon başlatır**: "en yakın benzinciyi bul, oraya götür" → bulur → Google Maps'te navigasyonu başlatır
- **Sesli cevap verir**: internet varken kaliteli (Google Chirp 3 HD), yokken offline (Piper)

### 1.2 Çalışma felsefesi: HİBRİT (online + offline)

Bu mimarinin kalbi. Siri'nin yaptığının aynısı: **basiti cihazda, karmaşığı bulutta.**

```
KOMUT GELİR → Uygulama bakar: internet var mı + bu komut basit/offline çözülebilir mi?
   │
   ├─ İNTERNET VAR
   │     ses → Groq Whisper (STT) → metin
   │     metin → FastAPI backend → Gemini (function calling) → aksiyon JSON
   │     [Gemini gerekirse: web search / web fetch / Google Places çağırır]
   │     aksiyon → telefon uygular (intent) + cevap → Google Chirp 3 HD (TTS) → ses
   │     (AKILLI MOD: araştırabilen, her şeyi yapan)
   │
   └─ İNTERNET YOK
         ses → Vosk (offline STT, cihazda) → metin
         metin → cihazda basit komut çözümleme (keyword/pattern + grammar)
         aksiyon → telefon uygular (intent) + cevap → Piper (offline TTS) → ses
         (TEMEL MOD: ara, alarm, fener, uygulama aç gibi kalıplı işler)
```

**Neden hibrit:** İnternet yokken bile temel işler (arama, alarm) çalışsın + internet varken tam zekâ devrede olsun + hız (basit komutlar buluta gidip dönmeyi beklemesin).

### 1.3 Neden bu mimari (Flutter + native köprü + backend)?

- **Flutter:** Kullanıcı Flutter/React Native biliyor, Kotlin bilmiyor. Tek kod tabanı.
- **İnce native (Kotlin) katman:** Sadece AccessibilityService (WhatsApp otomatik gönder) için. Geri kalan intent'ler `url_launcher` paketiyle Dart'tan ateşlenebiliyor.
- **Backend (FastAPI):** "Beyin" backend'de. Sebepleri: (1) API anahtarları telefonda değil backend'de güvende, (2) web search / web fetch / Places gibi araçlar backend'de döner, (3) konuşma hafızası ve mantık tek yerde toplanır.

---

## 2. Mimari Genel Bakış

### 2.1 İki ana parça

**A) Flutter App (Android) — "el, kulak, ağız"**
- Wake word dinleme (Porcupine)
- Ses kaydı + STT (online: Groq'a gönder / offline: Vosk)
- TTS (online: Google Chirp 3 HD / offline: Piper)
- İnternet durumu tespiti → online/offline mod seçimi
- Intent dispatch (alarm, ara, SMS, navigasyon, wa.me, uygulama açma)
- AccessibilityService köprüsü (WhatsApp otomatik gönder)
- Backend ile HTTP iletişimi
- GPS konum

**B) FastAPI Backend (Railway) — "beyin"**
- `/stt` — ses dosyası alır, Groq Whisper'a atar, Türkçe metin döner
- `/chat` — metin + konuşma geçmişi alır, Gemini'ye function calling ile atar, aksiyon JSON döner
- `/tts` — metin alır, Google Chirp 3 HD'ye atar, ses döner
- Gemini'nin kullanabileceği araçlar (tools): search_places, save_location, save_preference + yerleşik `google_search` grounding (web araması)
- Konuşma hafızası (session bazlı, stateful)
- (Sonraki faz) FCM push — proaktif öneriler için

### 2.2 Bileşen → Teknoloji haritası

| Katman | İnternet VAR | İnternet YOK |
|---|---|---|
| **STT** (ses→metin) | Groq Whisper (`whisper-large-v3-turbo`) | Vosk (`vosk-model-small-tr-0.3`) |
| **Beyin** (anlama+karar) | FastAPI backend + Gemini (function calling) | Cihazda keyword/pattern + Vosk grammar |
| **TTS** (metin→ses) | Google Cloud TTS (`Chirp 3 HD`, `tr-TR`) | Piper (`tr_TR-*-medium`, sherpa-onnx ile) |
| **Wake word** | Porcupine (cihazda, her durumda) | Porcupine (cihazda, her durumda) |

---

## 3. Teknoloji Stack'i (Kesinleşmiş Kararlar)

> Bu kararlar uzun bir araştırma ve değerlendirme sonucu verildi. Claude Code bunları **sorgulamadan uygulamalı** — her biri Türkçe + ücretsiz + uygun lisans kriterleriyle seçildi.

### 3.1 Backend (Python / FastAPI)

| Amaç | Kütüphane / Servis | Not |
|---|---|---|
| Web framework | **FastAPI** | + Uvicorn (ASGI server) |
| Deployment | **Railway** | GitHub repo bağlama yöntemiyle |
| LLM / beyin | **Google Gemini** (function calling) | `google-genai` SDK (yeni) ya da `google-generativeai` |
| STT (online) | **Groq Whisper** | `groq` Python client; model `whisper-large-v3-turbo` |
| TTS (online) | **Google Cloud TTS** | `google-cloud-texttospeech`; voice `tr-TR-Chirp3-HD-*` |
| Yer verisi | **Google Places API** | REST; gerçek restoran/mekan + puan + yorum |
| Web araştırma | **Gemini yerleşik `google_search` grounding** | AYRI API YOK. Gemini kendi arar+okur+sentezler. Ücretsiz: 5.000 prompt/ay |
| Veritabanı | **Railway PostgreSQL** | Kalıcı hafıza: konuşma geçmişi, kayıtlı konumlar, tercihler. `DATABASE_URL` env'den |
| ORM | **SQLAlchemy + Alembic** (veya SQLModel) | Migration yönetimi |

### 3.2 Flutter App (Dart)

| Amaç | Paket | Not |
|---|---|---|
| Wake word | **porcupine_flutter** | Custom keyword "Şahin" |
| Ses kaydı | **record** | Groq'a göndermek için kayıt |
| STT (offline) | **vosk_flutter** (veya `vosk_flutter_2`) | Türkçe model 35MB, grammar destekli |
| TTS (offline) | **sherpa_onnx** | Piper modelini çalıştırır (offline ses) |
| İntentler | **url_launcher** | `tel:`, `https://wa.me/...`, `google.navigation:q=` |
| Konum | **geolocator** | GPS |
| Backend iletişim | **dio** (veya `http`) | |
| İnternet tespiti | **connectivity_plus** | online/offline mod kararı |
| İzin yönetimi | **permission_handler** | |
| WhatsApp otomatik gönder | **Platform Channel + Kotlin** | AccessibilityService (native, ince katman) |

### 3.3 Ses modelleri (cihaza inecek dosyalar)

- **Vosk Türkçe:** `vosk-model-small-tr-0.3` (~35 MB) — APK'ye gömülmez, ilk açılışta indirilir/asset olarak yüklenir
- **Piper Türkçe:** `tr_TR-fettah-medium` (varsayılan; alternatifler `tr_TR-dfki-medium`, `tr_TR-fahrettin-medium`) — `.onnx` + `.onnx.json` ikilisi + sherpa-onnx runtime (~55 MB toplam)
- **Not:** Türkçe Piper'da sadece `medium` kalite var, `high` yok. Bu bir kısıt, kabul edildi.

---

## 4. Özellikler / Yetenekler (Function Calling Tool'ları)

Gemini'nin döndürebileceği aksiyonlar. Her biri net parametrelerle tanımlanır. Backend bunları yapılandırılmış JSON olarak alır, Flutter'a iletir, Flutter intent'i ateşler.

```
set_alarm(hour: int, minute: int, label: str)
    → Flutter: AlarmClock.ACTION_SET_ALARM intent
    → OFFLINE de çalışır (intent, internet gerektirmez)

make_call(target: str)              # "annemi ara", "Sevdem'i ara"
    → Flutter: rehberden numara bul (READ_CONTACTS) → tel: intent (ACTION_CALL)
    → OFFLINE de çalışır

send_sms(target: str, text: str)
    → Flutter: SMS intent, metin önceden doldurulmuş
    → OFFLINE de çalışır (metni kullanıcı söylerse)

send_whatsapp(target: str, text: str, include_location: bool, location_query: str)
    → Flutter: wa.me intent (sohbet açılır + metin kutuya yazılır)
    → include_location=true ise metne Google Maps LİNKİ eklenir (konum balonu DEĞİL)
    → "gönder" komutu gelince AccessibilityService gönder butonuna basar
    → GÖNDERMEDEN ÖNCE sesli onay: "Sevdem'e şunu gönderiyorum, onaylıyor musun?"

search_places(query: str, location: str)     # "Bodrum'da iyi restoran"
    → Backend: Google Places API → gerçek mekanlar + puan + yorum
    → ONLINE (internet şart)

[WEB ARAMA — AYRI TOOL DEĞİL]
    → Gemini'nin YERLEŞİK google_search grounding'i kullanılır.
    → Backend ayrı web_search/web_fetch tool'u YAZMAZ. Gemini kendi
      içinde arar, sayfaları işler, yorumları sentezler, kaynak gösterir.
    → google_search grounding + function calling AYNI ANDA çalışır
      (Gemini 3 modelleri bunu destekliyor).
    → Ücretsiz: Gemini 3 modellerinde ayda 5.000 grounded prompt.
    → ONLINE

navigate_to(query: str)              # "en yakın benzinci", restoran adı, "ev", "iş"

    → Flutter: konum al (GPS) → (gerekirse Places ile yer bul) →
      google.navigation:q=<koordinat> intent → Maps navigasyonu BAŞLAR
    → Yarı-offline: yer biliniyorsa intent offline da çalışır; "en yakın X bul" Places ister

open_app(app_name: str)              # "Spotify'ı aç"
    → Flutter: uygulama açma intent
    → OFFLINE de çalışır

create_calendar_event(title: str, datetime: str, ...)
    → Flutter: takvim etkinliği intent
    → OFFLINE de çalışır

save_location(label: str)            # "şu anki konumumu evim olarak kaydet"
    → Flutter: GPS'ten ANLIK konum alır (lat/lng) → backend'e label+koordinat
    → Backend: DB'ye yazar (örn. ev, iş, spor salonu)
    → ONLINE (DB'ye yazmak için; ama konum GPS'ten offline alınır, internet gelince senkron edilebilir)

get_saved_location(label: str)       # "eve götür" → DB'den ev koordinatı çekilir
    → Backend: DB'den okur → navigate_to'ya beslenir → Maps navigasyonu başlar

save_preference(key: str, value: str)  # genel kalıcı kişisel hafıza
    → "beni sabah 7'de uyandır her gün", "en sevdiğim mutfak İtalyan" gibi
    → Backend: DB'ye yazar

get_preference(key: str)             # kalıcı tercihi çek
    → Backend: DB'den okur

chat_reply(text: str)                # sadece konuşma, aksiyon yok
    → TTS ile seslendirilir
```

**Kişisel hafıza/profil katmanı:** save_location / save_preference ile asistan
kullanıcıyı kalıcı olarak tanır (ev/iş konumu, tercihler). "Eve götür", "işe ne
kadar var", "her zamanki yere git" bunun üstüne kurulur. Bu katman DB gerektirir
(bkz. bölüm 4.1).

**Genişletilebilirlik:** Yeni yetenek = yeni bir tool tanımı + Flutter'da karşılık gelen intent. Altyapı bir kez kurulunca eklemek kolay.

### 4.1 Veritabanı (DB) — kalıcı hafıza

> Karar: bellekte değil, **kalıcı veritabanı** kullanılır. Sebep: (1) asistan oturumlar
> arası konuşmayı hatırlasın, (2) save_location / save_preference gibi kalıcı kişisel
> hafıza özellikleri ("şu anki konumumu evim olarak kaydet") DB olmadan çalışmaz.

- **DB:** Railway'in yönetilen **PostgreSQL**'i (Railway projesine eklenir, bağlantı `DATABASE_URL` env variable olarak gelir).
- **ORM:** SQLAlchemy (+ Alembic migration) ya da SQLModel.
- **Tablolar (minimum):**
  - `conversations` — session bazlı konuşma geçmişi (oturumlar arası kalıcı)
  - `saved_locations` — label, lat, lng (ev, iş, vb.)
  - `preferences` — key, value (kalıcı tercihler)
  - `contacts_cache` — (opsiyonel) sık kişilerin çözümlenmiş eşleşmeleri
- **Not:** Tek kullanıcılık kişisel asistan olduğu için kullanıcı tablosu/auth karmaşıklığı gerekmez; basit bir `user_id` sabiti yeter.

---

## 5. Kritik Senaryolar (Kabul Testleri)

Bu senaryolar projenin "çalıştı" sayılması için geçmesi gereken uçtan uca akışlardır. Claude Code bunları doğrulama hedefi olarak kullanmalı.

### Senaryo A — Bodrum restoran (çok adımlı, online, en kapsamlı)
```
1. "Sevdem'le Bodrum'da yemek yiyeceğim, çevremdeki iyi restoranları söyle"
   → search_places("restoran", "Bodrum") → gerçek liste
   → (opsiyonel) Gemini grounding ile en iyi yerlerin yorumları okunur/sentezlenir
   → Gemini süzer, sesli önerir
2. "Tamam o iyiymiş, saat 8'de Sevdem'e buraya gidelim diye mesaj at"
   → konuşma hafızasından hangi restoran olduğu bilinir
   → send_whatsapp metni kurulur: "Akşam 8'de [restoran]'a gidelim mi?"
3. "Konumu da gönder"
   → metne Google Maps linki eklenir (location balonu değil)
4. "Gönder"
   → "Sevdem'e şunu gönderiyorum, onay?" → "evet"
   → wa.me intent + AccessibilityService → mesaj gider
```
**Doğrulama:** Sohbet bağlamı korunmalı (2. adımda restoran hatırlanmalı), mesaj Sevdem'in sohbetinde metin+link olarak gitmeli.

### Senaryo B — En yakın benzinci + navigasyon (yarı-offline)
```
"En yakın benzinciyi bul, oraya götür"
→ GPS konum → search_places("benzin istasyonu", konum) → en yakın
→ navigate_to → Google Maps navigasyonu başlar
```
**Doğrulama:** Maps gerçekten navigasyon modunda açılmalı (sadece "yön tarifi göster" değil).

### Senaryo C — "Şahin annemi ara" (wake word + offline temel komut)
```
"Şahin" (Porcupine uyandırır) → "annemi ara"
→ offline STT (Vosk) → komut çözümleme → rehberden "anne" → tel: intent
```
**Doğrulama:** İnternet KAPALIYKEN çalışmalı. Yanlış kişiyi aramamak için belirsizlikte sesli teyit.

---

## 6. Kullanıcı Tercihleri ve Kısıtlar

> Bu bölüm Claude Code'un kod stilini ve karar verme tarzını şekillendirir.

### 6.1 İletişim / dil
- Asistanın kullanıcıya konuşma dili: **Türkçe**, samimi ("kanka") register. Robotik/resmi değil.
- Sesli cevaplar **kısa ve net** olmalı (uzun paragraf değil): "Annenı arıyorum", "Alarm 8'e kuruldu", "Bodrum'da 3 yer buldum".

### 6.2 Teknik tercihler (kullanıcının yerleşik tercihleri)
- **Tam dosya çıktıları** tercih edilir, yarım/parça kod değil.
- **Çalıştırılmış/doğrulanmış kod** — "çalışıyor" demeden önce test edilmeli.
- Karmaşık şeylerde **adım adım** ilerle, her adımda doğrulama.
- Scope drift'ten kaçın — istenen şeyi yap, fazlasını ekleme, sapma.
- UI: koyu tema (dark) tercih edilir.

### 6.3 Mimari kısıtlar
- **Root GEREKMEZ.** Hiçbir çözüm root varsaymamalı. AccessibilityService root'suz çözüm.
- **AccessibilityService kırılgan** — WhatsApp arayüzü değişince gönder butonu bulma kodu kırılabilir. Bunu izole, bakımı kolay tut. Buton bulma stratejisi esnek olmalı (content-description, text, viewId gibi birden çok yöntem dene).
- **wa.me konum balonu YOK** — konum her zaman Maps linki olarak metne gömülür. (wa.me location balonu programatik gönderilemiyor.)
- Otomatik gönderme her zaman **sesli onay** arkasında (yanlış mesaj riskine karşı).

### 6.4 Maliyet kısıtı
- Tüm servisler **ücretsiz tier** içinde kalmalı. Kişisel kullanım hacmi:
  - Groq Whisper: günde 2.000 istek / saatte 7.200 sn ses (bedava) — fazlasıyla yeter
  - Gemini: cömert ücretsiz tier
  - Google TTS Chirp 3 HD: ayda 1.000.000 karakter bedava — fazlasıyla yeter
  - Google Places: ücretsiz kotası izlenmeli (en olası maliyet noktası burası)

---

## 7. GÜVENLİK (KRİTİK — Önce Bunu Oku)

> Bu projede daha önce API anahtarları sızdırıldı. Aşağıdaki kurallar pazarlık konusu değil.

### 7.1 Sır yönetimi
- **HİÇBİR API anahtarı, servis hesabı JSON'u, token koda gömülmez.** Ne backend'de, ne Flutter'da, ne commit'te.
- Backend sırları **sadece Railway Environment Variables**'tan okur (`os.environ`):
  - `GROQ_API_KEY`
  - `GEMINI_API_KEY`
  - `GOOGLE_APPLICATION_CREDENTIALS_JSON` (servis hesabı JSON'unun **tüm içeriği** string olarak; kod bunu geçici dosyaya yazıp `GOOGLE_APPLICATION_CREDENTIALS` path'ine işaret eder)
  - `GOOGLE_PLACES_API_KEY`
  - `DATABASE_URL` (Railway PostgreSQL otomatik sağlar)
  - `API_SHARED_SECRET` (backend endpoint koruması — bkz. 7.3)
  - NOT: Ayrı web arama API anahtarı YOK (Gemini grounding kullanılıyor).
- **`.gitignore`** ilk iş olarak kurulmalı: `.env`, `*.json` (servis hesabı), `credentials/`, vb.
- `.env.example` dosyası oluşturulmalı (gerçek değerler OLMADAN, sadece anahtar isimleri).

### 7.2 Flutter tarafı
- Flutter app **hiçbir LLM/STT/TTS API anahtarı tutmaz.** Tüm bu çağrılar backend üzerinden gider.
- Tek istisna: Porcupine AccessKey (cihazda wake word için gerekli) — bu yine de doğrudan repoya commit edilmez, build-time config (örn. `--dart-define`) ile verilir.

### 7.3 Backend güvenliği
- Backend endpoint'leri en azından basit bir token/secret ile korunmalı (rastgele biri senin Gemini/Groq kotanı harcamasın). `API_SHARED_SECRET` env variable + Flutter isteğe header olarak ekler.

---

## 8. Repo Yapısı (Önerilen)

```
jarvis/
├── backend/                      # FastAPI (Railway'e bu deploy edilir)
│   ├── main.py                   # FastAPI app, endpoint'ler
│   ├── routers/
│   │   ├── stt.py                # /stt → Groq Whisper
│   │   ├── chat.py               # /chat → Gemini function calling
│   │   └── tts.py                # /tts → Google Chirp 3 HD
│   ├── tools/                    # Gemini'nin çağırdığı araçlar (custom function'lar)
│   │   ├── places.py             # Google Places
│   │   ├── locations.py          # save_location / get_saved_location
│   │   └── preferences.py        # save_preference / get_preference
│   │   # NOT: web arama AYRI dosya değil — Gemini'nin yerleşik google_search
│   │   #      grounding'i chat.py'de tool olarak etkinleştirilir.
│   ├── db/
│   │   ├── database.py           # SQLAlchemy engine, DATABASE_URL'den
│   │   ├── models.py             # conversations, saved_locations, preferences
│   │   └── migrations/           # Alembic
│   ├── core/
│   │   ├── config.py             # env okuma (os.environ)
│   │   ├── memory.py             # konuşma hafızası (DB'ye yazan)
│   │   └── credentials.py        # Google JSON'u env'den dosyaya yazma
│   ├── requirements.txt
│   ├── Procfile / railway.json   # Railway config
│   ├── .env.example              # SADECE anahtar isimleri
│   └── .gitignore
│
└── app/                          # Flutter (Android)
    ├── lib/
    │   ├── main.dart
    │   ├── services/
    │   │   ├── wake_word.dart     # Porcupine
    │   │   ├── stt_online.dart    # ses kaydı → backend /stt
    │   │   ├── stt_offline.dart   # Vosk
    │   │   ├── tts_online.dart    # backend /tts → çal
    │   │   ├── tts_offline.dart   # Piper (sherpa_onnx)
    │   │   ├── connectivity.dart  # online/offline tespit
    │   │   ├── backend.dart       # /chat çağrısı
    │   │   └── command_offline.dart # offline keyword çözümleme
    │   ├── actions/               # intent dispatch
    │   │   ├── call.dart          # url_launcher tel:
    │   │   ├── alarm.dart
    │   │   ├── whatsapp.dart      # wa.me
    │   │   ├── navigation.dart    # google.navigation
    │   │   └── open_app.dart
    │   └── ui/                    # koyu tema
    ├── android/
    │   └── app/src/main/kotlin/.../
    │       ├── MainActivity.kt
    │       └── WhatsAppAccessibilityService.kt  # AccessibilityService
    ├── pubspec.yaml
    └── assets/models/             # Vosk + Piper modelleri (veya runtime indir)
```

---

## 9. Android İzinleri

`AndroidManifest.xml`'de tanımlanacak + runtime'da istenecek:

- `INTERNET` — backend iletişimi
- `RECORD_AUDIO` — ses dinleme
- `READ_CONTACTS` — "annemi/Sevdem'i ara" → numara çözme
- `CALL_PHONE` — direkt arama (ACTION_CALL)
- `ACCESS_FINE_LOCATION` — "çevremdeki", "en yakın" için
- **AccessibilityService** — `AndroidManifest`'te servis tanımı + kullanıcı Ayarlar'dan elle etkinleştirir (her cihazda bir kez). Sadece WhatsApp gönder butonu için.

---

## 10. ADIM ADIM UYGULAMA PLANI (Fazlı)

> En önemli kural: **her faz kendi başına çalışan bir şey bırakır + kendi doğrulama adımı vardır.** Bir faz bitmeden sonraki başlamaz. Yarım kalsa bile elde çalışan bir parça olur.

### FAZ 0 — Altyapı ve güvenlik iskeleti
- Repo yapısı kurulur (bölüm 8)
- `.gitignore` + `.env.example` (bölüm 7)
- Backend: boş FastAPI, `/health` endpoint
- Railway'e GitHub repo bağlanır + **Railway PostgreSQL eklenir** (`DATABASE_URL` gelir)
- **Doğrulama:** Railway URL'ine `GET /health` → 200 döner. DB bağlantısı kurulur (basit bir test sorgusu). Hiçbir sır commit'te yok (`git log` / dosya kontrolü).

### FAZ 1 — Backend beyin: /chat + Gemini function calling + DB hafıza
- Gemini bağlanır (env'den key)
- DB modelleri kurulur (`conversations`, `saved_locations`, `preferences`) + Alembic migration
- Bölüm 4'teki tool tanımları yapılır (önce sadece `set_alarm`, `make_call`, `chat_reply`)
- `/chat`: metin alır → Gemini function calling → aksiyon JSON döner
- Konuşma hafızası **DB'ye** yazılır (oturumlar arası kalıcı)
- **Doğrulama:** curl/Postman ile `/chat`'e "saat 8'e alarm kur" → `{"action":"set_alarm","hour":8,...}` döner. "Annemi ara" → `{"action":"make_call","target":"anne"}`. Çok adımlı: iki ardışık istekte bağlam korunur. Backend restart'tan SONRA bile geçmiş DB'den okunur.

### FAZ 2 — Backend STT: /stt + Groq
- Groq client bağlanır (env'den key)
- `/stt`: ses dosyası (multipart) alır → `whisper-large-v3-turbo` → Türkçe metin döner
- **Doğrulama:** Türkçe bir ses dosyası (.wav/.m4a) gönder → doğru Türkçe metin döner.

### FAZ 3 — Backend TTS: /tts + Google Chirp 3 HD
- Google credentials env'den dosyaya yazılır (bölüm 7.1)
- `/tts`: metin alır → `tr-TR-Chirp3-HD-*` → ses (mp3) döner
- **Doğrulama:** "Selam kanka" gönder → doğal Türkçe ses dosyası döner, dinlenince anlaşılır.

### FAZ 4 — Araştırma + mekan + kişisel hafıza tool'ları
- `search_places` (Google Places) implement edilir
- Gemini'nin **yerleşik `google_search` grounding'i** etkinleştirilir (ayrı API yok; grounding + function calling birlikte)
- `save_location` / `get_saved_location` / `save_preference` / `get_preference` tool'ları (DB'ye yazan/okuyan)
- **Doğrulama:** (1) "Bodrum'da iyi restoran öner" → gerçek mekanlar döner (uydurma değil). (2) "İtalya'nın başkenti ne" → Gemini grounding ile güncel cevap. (3) "şu anki konumumu evim olarak kaydet" → DB'ye yazılır, "evim nerede" → koordinat döner.


### FAZ 5 — Flutter iskelet + en basit akış
- Flutter projesi (koyu tema), izinler, `connectivity_plus`
- Buton → ses kaydet (`record`) → backend `/stt` → metin → backend `/chat` → backend `/tts` → ses çal
- Henüz wake word yok, butonla tetikleniyor
- **Doğrulama:** Butona bas, "saat 8'e alarm kur" de → metin doğru, aksiyon JSON döner, cevap seslendirilir.

### FAZ 6 — Flutter intent dispatch (online aksiyonlar)
- `url_launcher` ile: `make_call` (tel:), `set_alarm`, `open_app`, `navigate_to` (google.navigation)
- `geolocator` ile GPS → "en yakın benzinci" senaryosu + `save_location` (anlık konum → backend)
- Kayıtlı konuma navigasyon: "eve götür" → `get_saved_location` → `navigate_to`
- **Doğrulama:** Senaryo B (benzinci + navigasyon) uçtan uca çalışır. "Annemi ara" gerçekten arar. "Şu anki konumumu evim olarak kaydet" → sonra "eve götür" → ev konumuna navigasyon başlar.

### FAZ 7 — WhatsApp: wa.me + AccessibilityService
- `send_whatsapp`: wa.me intent (metin + Maps linki dolu)
- Kotlin AccessibilityService (platform channel) → gönder butonu
- Göndermeden önce sesli onay akışı
- **Doğrulama:** Senaryo A (Bodrum) uçtan uca çalışır. Onay olmadan göndermez. Maps linki metinde.

### FAZ 8 — Offline mod: Vosk (STT) + Piper (TTS) + komut çözümleme
- `vosk_flutter` + Türkçe model (grammar ile komut kümesi sınırlama)
- `sherpa_onnx` + Piper Türkçe model
- `connectivity` ile online/offline otomatik geçiş
- Offline komut çözümleyici (keyword/pattern): ara, alarm, fener, uygulama aç
- **Doğrulama:** Senaryo C (internet KAPALI → "Şahin annemi ara") çalışır. Offline'da sesli cevap (Piper) gelir.

### FAZ 9 — Wake word: Porcupine
- `porcupine_flutter` + custom "Şahin" keyword
- Sürekli dinleme → uyanma → akışı tetikleme
- **Doğrulama:** "Şahin" deyince asistan uyanır, sonraki cümleyi işler. Yanlış tetikleme makul seviyede.

### FAZ 10 (opsiyonel) — Proaktif öneriler
- FCM push (backend tetikler, telefon yorulmaz)
- Zamanlı/olay bazlı: sabah brifingi, hava uyarısı, takvim hatırlatma
- **Doğrulama:** Backend belirli koşulda push atar, telefon bildirim gösterir, dokununca asistan açılır.

---

## 11. CLAUDE.md Şablonu (Repoya Konacak — Kalıcı Hafıza)

> Best practice (Anthropic + topluluk): CLAUDE.md **200 satır altında** olmalı, WHAT/WHY/HOW etrafında yapılanmalı, kodun çıkaramayacağı iş bağlamını içermeli, prosa değil dosyalara işaret etmeli. Aşağıdaki şablonu repo köküne `CLAUDE.md` olarak koy.

```markdown
# JARVIS — Türkçe Sesli Asistan

## Ne (What)
Türkçe sesli asistan. Flutter (Android) app + FastAPI (Railway) backend.
Hibrit: internet varken Gemini bulut zekâsı, yokken cihazda temel komutlar.
Tam spec: SPEC.md (her zaman ona başvur).

## Tech Stack
- Backend: FastAPI + Uvicorn, Python. Deploy: Railway. DB: Railway PostgreSQL (SQLAlchemy + Alembic).
- LLM: Google Gemini (function calling + yerleşik google_search grounding).
- STT online: Groq Whisper (whisper-large-v3-turbo). Offline: Vosk (tr-0.3).
- TTS online: Google Cloud TTS (tr-TR-Chirp3-HD-*). Offline: Piper (sherpa-onnx).
- App: Flutter/Dart. Native köprü: Kotlin (sadece AccessibilityService).
- Wake word: Porcupine, custom keyword "Şahin".

## Komutlar
- Backend lokal: `cd backend && uvicorn main:app --reload`
- Backend test: `cd backend && pytest`
- DB migration: `cd backend && alembic upgrade head`
- Flutter çalıştır: `cd app && flutter run`
- Flutter build: `cd app && flutter build apk`

## Mimari (dosyalar)
- Backend endpoint'leri: backend/routers/ (stt, chat, tts)
- Gemini custom araçları: backend/tools/ (places, locations, preferences)
- Web arama: AYRI dosya değil — Gemini google_search grounding chat.py'de
- DB: backend/db/ (database, models, migrations)
- Flutter servisleri: app/lib/services/
- Intent dispatch: app/lib/actions/
- AccessibilityService: app/android/.../WhatsAppAccessibilityService.kt

## KURALLAR (kritik)
- Sır YOK: hiçbir API key/JSON koda gömülmez. Backend os.environ'dan okur. .env commit edilmez.
- Flutter hiçbir LLM/STT/TTS key tutmaz; hepsi backend üzerinden.
- Root varsayma. AccessibilityService root'suz çözüm.
- wa.me konum = Maps linki (balon değil). Otomatik gönder = sesli onay arkasında.
- Web arama = Gemini yerleşik google_search grounding. Ayrı arama API'si EKLEME.
- Kişi çözme = rehberden (READ_CONTACTS). Mini liste yok.
- Hafıza = kalıcı DB. Konuşma geçmişi + kayıtlı konumlar + tercihler DB'de.
- Tam dosya çıktısı ver, parça değil. "Çalışıyor" demeden test et.
- Türkçe + ücretsiz tier kararları SPEC.md'de; sorgulamadan uygula.
- Scope drift yok: istenen fazı yap, fazlasını ekleme.

## İş bağlamı
Kullanıcı (Furkan) Flutter/React Native biliyor, Kotlin bilmiyor — Kotlin'i minimumda tut.
Asistan kullanıcıya kısa, samimi Türkçe konuşur. UI koyu tema.
```

---

## 12. Bu Spec'i Claude Code'a Nasıl Vereceksin (İş Akışı)

> Araştırmadan çıkan en etkili yöntem. Adım adım.

### Adım 1 — Repoyu hazırla
- Boş bir GitHub reposu aç (`jarvis` gibi)
- İçine bu `JARVIS_SPEC.md`'yi koy
- Bölüm 11'deki şablonla `CLAUDE.md` oluştur

### Adım 2 — Claude Code'u başlat
- Terminalde repo klasöründe `claude` çalıştır
- İlk olarak `/init` çalıştır (Claude Code mevcut yapıdan temel CLAUDE.md taslağı çıkarır; sonra bölüm 11'le birleştir)

### Adım 3 — Plan modunda başlat (kod yazmadan önce)
İlk prompt olarak şunu ver:
```
SPEC.md dosyasını oku. Bu bir Türkçe sesli asistan projesinin tam
spesifikasyonu. Önce sadece FAZ 0 ve FAZ 1'i planla (kod yazma henüz).
Plan modunda kal. Belirsiz veya senin için riskli gördüğün noktaları
AskUserQuestion ile bana sor — özellikle benim düşünmediğim edge case'ler
ve teknik tercihler hakkında. Sonra net bir uygulama planı çıkar.
```

### Adım 4 — Faz faz ilerlet
- **Her fazı ayrı/temiz oturumda çalıştır** (best practice: temiz context).
- Her faz için: "SPEC.md FAZ N'i uygula. Bölümdeki doğrulama adımını çalıştırıp kanıtla."
- Faz bitince, doğrulama geçtiyse → `git commit` → sonraki faza geç.
- Context şişerse `/clear` ile temizle (SPEC.md ve CLAUDE.md zaten dosyada, kaybolmaz).

### Adım 5 — Sırları sen gir
- Claude Code kodu yazar ama **anahtarları Claude Code'a verme.**
- Anahtarları sen Railway Environment Variables'a (backend) ve `--dart-define` (Porcupine) ile girersin.
- Lokal test için `.env` dosyasını sen oluşturursun (commit edilmez, `.gitignore`'da).

### Adım 6 — Retro (her faz/oturum sonu)
- "Bu oturumda ne öğrendin?" diye sor. Çıkan dersleri doğru yere ekle:
  proje konseptleri → CLAUDE.md, mimari kararlar → SPEC.md, tekrarlayan workflow → skill.

---

## 13. Kapsam Dışı (Bu Sürümde YOK)

> Net olmak önemli — Claude Code bunlara girmemeli.

- **iOS** — şimdilik sadece Android. (Flutter ileride iOS verir ama hedef değil.)
- **Root gerektiren özellikler** — sistem ayarlarını derinden değiştirme, başka app verisi okuma (AccessibilityService'in yaptığı hariç).
- **WhatsApp konum balonu** (haritalı location mesajı) — sadece Maps linki.
- **WhatsApp bot / Business API** — sadece kullanıcının kendi telefonundan wa.me + AccessibilityService.
- **Kendi ses modeli eğitme / fine-tune** — hazır Piper/Chirp kullanılır.
- **Sürekli gerçek-zamanlı proaktiflik** (anlık ortam izleme) — sadece zamanlı/olay bazlı push (Faz 10, opsiyonel).
- **ElevenLabs** — ücretsiz tier'ı yetersiz; online TTS = Google Chirp 3 HD.
- **Çok kullanıcılı / hesap sistemi** — tek kullanıcılık kişisel asistan.

---

## 14. Açık Sorular (Claude Code Plan Modunda Sorabilir)

Bunlar henüz netleşmemiş, Claude Code plan aşamasında kullanıcıya sorabilir:

1. ~~Wake word seçimi~~ → **KARARLAŞTI: "Şahin"** (Porcupine custom keyword). Kullanım: "Şahin annemi ara".
2. ~~Web arama API'si~~ → **KARARLAŞTI: Gemini yerleşik `google_search` grounding.** Ayrı API (Tavily/Brave/SerpAPI) YOK. Bölüm 4'e bakınız.
3. ~~Kişi listesi~~ → **KARARLAŞTI: rehberden çözülür** (`READ_CONTACTS`). Mini liste yok. "Annem" için rehberde ilişki/isim tanımlı olmalı.
4. ~~Backend hafıza~~ → **KARARLAŞTI: kalıcı DB** (Railway PostgreSQL). Bölüm 4.1'e bakınız.
5. **Offline komut kapsamı (HÂLÂ AÇIK):** Offline'da kesin olanlar: ara, alarm. Eklenebilecekler: el feneri aç/kapa, uygulama aç. Claude Code plan modunda kullanıcıya sorabilir veya bu üçüyle başlayabilir.
6. **Mekan verisi — Places API mi Gemini Maps grounding mi (HÂLÂ AÇIK):** Google Places API'nin ücretsiz kotası vs. Gemini'nin Maps grounding'i ($14-25/1000, ücretli). Başlangıç önerisi: Places API ücretsiz kotası. Faz 4'te netleştirilir.

---

**SON NOT (Claude Code'a):** Bu spec kapsamlı ama esnek. Bir faz içinde teknik bir engelle karşılaşırsan, SPEC.md'nin ruhunu koru (hibrit yapı, Türkçe, ücretsiz, güvenli, root'suz) ama takıldığın yeri kullanıcıya AskUserQuestion ile sor. Asla sır gömme. Her faz sonunda doğrulama adımını gerçekten çalıştır.
