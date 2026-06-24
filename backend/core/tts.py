"""Google Cloud TTS (Chirp 3 HD) ile metin→ses (SPEC Faz 3). ONLINE TTS."""
import logging

from google.cloud import texttospeech

from core.config import settings
from core.credentials import ensure_google_credentials

logger = logging.getLogger("jarvis.tts")

_client: texttospeech.TextToSpeechClient | None = None


def _get_client() -> texttospeech.TextToSpeechClient:
    global _client
    if _client is None:
        ensure_google_credentials()  # JSON env → temp dosya → GOOGLE_APPLICATION_CREDENTIALS
        _client = texttospeech.TextToSpeechClient()
    return _client


def synthesize(text: str, voice: str | None = None) -> bytes:
    """Türkçe metni mp3 sese çevirir (tr-TR-Chirp3-HD-*)."""
    client = _get_client()
    synthesis_input = texttospeech.SynthesisInput(text=text)
    voice_params = texttospeech.VoiceSelectionParams(
        language_code=settings.GOOGLE_TTS_LANGUAGE,
        name=voice or settings.GOOGLE_TTS_VOICE,
    )
    audio_config = texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.MP3,
    )
    response = client.synthesize_speech(
        input=synthesis_input, voice=voice_params, audio_config=audio_config
    )
    return response.audio_content


def list_turkish_voices() -> list[str]:
    """Mevcut tr-TR seslerini listeler (doğrulama/seçim için)."""
    client = _get_client()
    resp = client.list_voices(language_code=settings.GOOGLE_TTS_LANGUAGE)
    return sorted(v.name for v in resp.voices)
