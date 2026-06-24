import 'package:flutter/services.dart';

/// WhatsApp otomatik gönderme köprüsü (Faz 7) — Kotlin AccessibilityService.
/// Gönderme HER ZAMAN kullanıcının sesli onayından SONRA çağrılır.
class WhatsAppService {
  static const MethodChannel _ch =
      MethodChannel('com.projemobilejarvis.sahin/accessibility');

  /// Erişilebilirlik servisi cihazda açık mı?
  Future<bool> isEnabled() async {
    try {
      return (await _ch.invokeMethod<bool>('isServiceEnabled')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ayarlar > Erişilebilirlik ekranını açar (kullanıcı listeden Şahin'i açar).
  Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openAccessibilitySettings');
    } catch (_) {}
  }

  /// Sohbeti metin dolu açar ve gönder düğmesine basar. phone: sadece rakam, ülke kodlu (905...).
  Future<bool> sendWhatsApp(String phone, String text) async {
    try {
      return (await _ch.invokeMethod<bool>(
              'sendWhatsApp', {'phone': phone, 'text': text})) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
