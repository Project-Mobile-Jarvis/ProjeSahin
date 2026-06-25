import 'package:flutter/services.dart';

/// Faz 11 — Native MicAssistantService köprüsü.
/// Mic'in tek sahibi native servis: Vosk wake ("Şahin") + komut kaydı + /stt.
/// Flutter sadece servisi başlatır ve çözülen komut METNİNİ alır.
class NativeMic {
  static const MethodChannel _mic = MethodChannel('com.projemobilejarvis.sahin/mic');
  static const EventChannel _cmd = EventChannel('com.projemobilejarvis.sahin/command');

  /// Servisi başlatır. Activity ÖN PLANDAYKEN çağrılmalı (Android 14 mikrofon kuralı).
  static Future<void> start({
    required String backend,
    required String apiKey,
    required String keyterms,
  }) async {
    try {
      await _mic.invokeMethod('startMic', {
        'backend': backend,
        'apikey': apiKey,
        'keyterms': keyterms,
      });
    } catch (_) {}
  }

  /// Butondan/onaydan elle tetikleme: wake beklemeden komutu kaydet.
  static Future<void> captureNow() async {
    try {
      await _mic.invokeMethod('captureNow');
    } catch (_) {}
  }

  static Future<void> setKeyterms(String keyterms) async {
    try {
      await _mic.invokeMethod('setKeyterms', {'keyterms': keyterms});
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _mic.invokeMethod('stopMic');
    } catch (_) {}
  }

  /// Ön planda native servisin çözdüğü komut metinleri.
  static Stream<String> commands() => _cmd
      .receiveBroadcastStream()
      .where((e) => e is String && e.trim().isNotEmpty)
      .cast<String>();
}
