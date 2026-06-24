# ProjeSahin — JARVIS Türkçe Sesli Asistan

"Şahin" wake word'üyle çalışan, Türkçe konuşan kişisel sesli asistan.
**Hibrit mimari:** internet varken bulut zekâsı (Gemini), yokken cihazda temel komutlar.

- 📱 **App:** Flutter (Android)
- 🧠 **Backend:** FastAPI + PostgreSQL (Railway)
- 🗣️ **STT/TTS:** Groq Whisper / Vosk · Google Chirp 3 HD / Piper
- 🤖 **LLM:** Google Gemini (function calling + google_search grounding)

> Tam spesifikasyon: [SPEC.md](SPEC.md) · Geliştirici rehberi: [CLAUDE.md](CLAUDE.md)

## Durum
- ✅ Faz 0 — Altyapı + güvenlik iskeleti
- ✅ Faz 1 — Backend beyin: `/chat` + Gemini function calling + DB hafıza
- ⬜ Faz 2+ — STT, TTS, araştırma, Flutter app, offline mod, wake word

## Backend — hızlı başlangıç
```bash
cd backend
python -m venv .venv && .venv/Scripts/activate      # Windows
pip install -r requirements.txt
cp .env.example .env            # değerleri doldur (DATABASE_URL, API_SHARED_SECRET, GEMINI_API_KEY)
alembic upgrade head
uvicorn main:app --reload
```

## Güvenlik
Hiçbir API anahtarı koda gömülmez; backend tüm sırları ortam değişkenlerinden okur.
`.env` commit **edilmez**. Detay: [SPEC.md](SPEC.md) bölüm 7.
