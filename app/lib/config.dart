/// Uygulama yapılandırması. Sırlar koda gömülmez — build sırasında --dart-define ile verilir.
///
/// Çalıştırma örneği:
///   flutter run --dart-define=API_KEY=PAYLASILAN_SIR
///               --dart-define=BACKEND_URL=https://projesahin-production.up.railway.app
class Config {
  /// Backend taban adresi. Varsayılan: production (Railway).
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://projesahin-production.up.railway.app',
  );

  /// Backend paylaşılan sırrı (X-API-Key). --dart-define=API_KEY=... ile verilir.
  static const String apiKey = String.fromEnvironment('API_KEY', defaultValue: '');

  /// Konuşma oturumu — sabit tutulursa hafıza açılışlar arası korunur (backend DB).
  static const String sessionId = 'mobile-furkan';

  static bool get isConfigured => apiKey.isNotEmpty;
}
