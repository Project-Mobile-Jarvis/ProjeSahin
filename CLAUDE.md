# JARVIS — Türkçe Sesli Asistan

## Ne (What)
Türkçe sesli asistan. Flutter (Android) app + FastAPI (Railway) backend.
Hibrit: internet varken Gemini bulut zekâsı, yokken cihazda temel komutlar.
Tam spec: SPEC.md (her zaman ona başvur).

## Durum (fazlar)
- [x] Faz 0 — Altyapı + güvenlik iskeleti (repo, /health, yerel Postgres)
- [x] Faz 1 — Backend beyin: /chat + Gemini function calling + DB hafıza
      → **Railway'de CANLI:** https://projesahin-production.up.railway.app (root dir=backend, port 8080)
      → Repo: github.com/Project-Mobile-Jarvis/ProjeSahin (main, auto-deploy)
- [x] Faz 2 — /stt (Groq Whisper, whisper-large-v3-turbo, language=tr) — Railway'de CANLI (ses→metin→/chat e2e doğrulandı)
- [x] Faz 3 — /tts (Google Chirp 3 HD, varsayılan ses tr-TR-Chirp3-HD-Achird) — Railway'de CANLI (metin→mp3 doğrulandı)
- [~] Faz 4 — Agentic döngü + tool'lar: navigate_to, save/get_saved_location, save/get_preference
      grounding (google_search). search_places (Places API). save/get + navigate ("eve götür") + grounding YEREL doğrulandı.
      search_places: Places API anahtarı bekliyor. Railway'e GOOGLE_PLACES_API_KEY eklenecek.
- [ ] Faz 5–9 — Flutter app   [ ] Faz 10 — Proaktif (opsiyonel)

## Tech Stack
- Backend: FastAPI + Uvicorn, Python 3.13. Deploy: Railway. DB: Railway PostgreSQL (SQLAlchemy 2.0 + Alembic).
- LLM: Google Gemini, `google-genai` SDK (function calling + yerleşik google_search grounding).
  Model: `gemini-flash-latest` (birincil) + GEMINI_FALLBACK_MODELS zinciri; 503/504 yoğunlukta yedeğe geçer; konuşma boyunca model SABİTLENİR (thought_signature tutarlılığı). SDK iç retry kapalı.
  Thinking: GEMINI_THINKING_BUDGET=-1 (modelin varsayılanı) — Gemini 3 agentic/çok-adımlı tool kullanımı thought_signature gerektirir; 0 yaparsan server-tool döngüsü 400 verir.
  Agentic döngü: sunucu tool'ları (search_places, locations, preferences) backend çalıştırıp Gemini'ye geri besler; cihaz tool'ları (navigate_to, set_alarm, make_call) Flutter'a döner. Kod: backend/core/llm.py, backend/tools/registry.py.
- STT online: Groq Whisper (whisper-large-v3-turbo). Offline: Vosk (tr-0.3).
- TTS online: Google Cloud TTS (tr-TR-Chirp3-HD-*). Offline: Piper (sherpa-onnx).
- App: Flutter/Dart. Native köprü: Kotlin (sadece AccessibilityService).
- Wake word: Porcupine, custom keyword "Şahin".

## Komutlar
- Yerel DB: `docker compose up -d` (kök dizinde)
- Backend lokal: `cd backend && uvicorn main:app --reload`
- Backend test: `cd backend && pytest`
- DB migration: `cd backend && alembic upgrade head`
- Flutter çalıştır: `cd app && flutter run` (Faz 5+)
- Flutter build: `cd app && flutter build apk` (Faz 5+)

## Mimari (dosyalar)
- Backend endpoint'leri: backend/routers/ (chat, stt; sonra tts)
- STT (Groq Whisper): backend/core/stt.py + routers/stt.py
- TTS (Google Chirp 3 HD): backend/core/tts.py + routers/tts.py; kimlik: backend/core/credentials.py
- Gemini araç tanımları: backend/tools/definitions.py
- Gemini istemci + function_call ayrıştırma: backend/core/llm.py
- Konuşma hafızası (DB): backend/core/memory.py
- Web arama: AYRI dosya değil — Gemini google_search grounding chat.py'de (Faz 4)
- DB: backend/db/ (database, models, migrations)
- Config/güvenlik: backend/core/ (config, security)
- Flutter servisleri: app/lib/services/ (Faz 5+)
- Intent dispatch: app/lib/actions/ (Faz 6+)
- AccessibilityService: app/android/.../WhatsAppAccessibilityService.kt (Faz 7)

## API sözleşmesi (/chat)
İstek `{session_id, message}` → Cevap `{action, args, reply}`.
action = Gemini'nin çağırdığı fonksiyon adı, args = argümanları, reply = kısa Türkçe TTS metni.
Düz sohbet → `{action:"chat_reply", args:{text}, reply}`. Header: `X-API-Key: API_SHARED_SECRET`.

## KURALLAR (kritik)
- Sır YOK: hiçbir API key/JSON koda gömülmez. Backend os.environ'dan (pydantic-settings) okur. .env commit edilmez.
- Flutter hiçbir LLM/STT/TTS key tutmaz; hepsi backend üzerinden.
- Function calling MANUEL: Gemini'ye Python callable verilmez (AFC kapalı). Aksiyonu Flutter uygular, backend değil.
- Root varsayma. AccessibilityService root'suz çözüm.
- wa.me konum = Maps linki (balon değil). Otomatik gönder = sesli onay arkasında.
- Web arama = Gemini yerleşik google_search grounding. Ayrı arama API'si EKLEME.
- Kişi çözme = rehberden (READ_CONTACTS). Mini liste yok.
- Hafıza = kalıcı DB. Konuşma geçmişi + kayıtlı konumlar + tercihler DB'de.
- Tam dosya çıktısı ver, parça değil. "Çalışıyor" demeden test et.
- Türkçe + ücretsiz tier kararları SPEC.md'de; sorgulamadan uygula.
- Scope drift yok: istenen fazı yap, fazlasını ekleme.
- ⚠️ GCP billing: bir projede faturalama açılınca Gemini ücretsiz tier kaybolur → Places ile Gemini ayrı proje/anahtar.

## İş bağlamı
Kullanıcı (Furkan) Flutter/React Native biliyor, Kotlin bilmiyor — Kotlin'i minimumda tut.
Asistan kullanıcıya kısa, samimi Türkçe konuşur. UI koyu tema.
