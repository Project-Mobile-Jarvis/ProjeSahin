import 'dart:ui';

import 'package:flutter/services.dart'; // HapticFeedback
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'backend.dart';
import 'recorder.dart';
import 'wakeword.dart';

/// Faz 10 — Arka plan wake word. Vosk dinleme SERVİSİN KENDİ isolate'ında çalışır
/// (uygulama swipe'lansa/kapatılsa bile sürer).
///
/// HIZ: "Şahin" duyulur duyulmaz komut HEMEN serviste kaydedilir (app açılmasını beklemeden),
/// Deepgram'a yollanır, SONUÇ (metin) main'e verilir → app sadece göstermek/aksiyon için açılır.
/// Servis-içi kayıt çalışmazsa (isolate plugin sorunu) eski yola düşer: 'capture' sinyali → main kaydeder.

@pragma('vm:entry-point')
void wakeServiceCallback() {
  FlutterForegroundTask.setTaskHandler(WakeTaskHandler());
}

class WakeTaskHandler extends TaskHandler {
  WakeWordService? _wake;
  final Recorder _recorder = Recorder();
  final BackendClient _backend = BackendClient();
  String _keyterms = '';
  bool _capturing = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized(); // bu isolate'ta plugin kanallarını kaydet
    try {
      final wake = WakeWordService();
      await wake.init();
      wake.listen(onCommand: _onCommand, onWake: _onWake);
      await wake.start();
      _wake = wake;
    } catch (e) {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Şahin',
        notificationText: 'Dinleme başlatılamadı (servis)',
      );
    }
  }

  /// "Şahin" duyuldu → komutu HEMEN serviste kaydet → Deepgram → main'e ver.
  /// (App açılmasını beklemez; bu yüzden hızlı.)
  Future<void> _onWake() async {
    if (_capturing) return;
    _capturing = true;
    try {
      HapticFeedback.mediumImpact(); // "dinliyorum" hissi (cep/ekran kapalı için)
    } catch (_) {}
    await _wake?.stop(); // Vosk mic'i kayda bıraksın

    String text = '';
    var serviceRecordWorks = true;
    try {
      final path = await _recorder.recordUntilSilence();
      if (path != null) {
        text = await _backend.stt(path, keyterms: _keyterms);
      }
    } catch (_) {
      serviceRecordWorks = false; // isolate'ta record/path_provider çalışmadı → fallback
    }

    _capturing = false;
    await _wake?.start(); // wake'i geri aç (sıradaki "Şahin" için)

    if (!serviceRecordWorks) {
      await _signalCaptureFallback(); // eski yol: main kaydetsin
      return;
    }
    if (text.trim().isNotEmpty) {
      await _deliver({'cmd': text});
    }
    // text boşsa kullanıcı bir şey demedi → sadece bekle (yeni "Şahin"e hazır).
  }

  /// (WhatsApp onayı) armForCommand sonrası kısa Vosk yanıtı ("evet/iptal") → main.
  Future<void> _onCommand(String command) async {
    await _deliver({'cmd': command});
  }

  /// Sonucu main'e iletir: ön plandaysa direkt, değilse kaydet + app'i öne getir.
  Future<void> _deliver(Map<String, Object> data) async {
    if (await FlutterForegroundTask.isAppOnForeground) {
      FlutterForegroundTask.sendDataToMain(data);
    } else {
      if (data['cmd'] is String) {
        await FlutterForegroundTask.saveData(key: 'pending_command', value: data['cmd'] as String);
      }
      await _bringUp();
    }
  }

  /// Servis kaydı çalışmazsa: main'in kaydetmesini iste (eski davranış).
  Future<void> _signalCaptureFallback() async {
    if (await FlutterForegroundTask.isAppOnForeground) {
      FlutterForegroundTask.sendDataToMain({'capture': true});
    } else {
      await FlutterForegroundTask.saveData(key: 'pending_capture', value: true);
      await _bringUp();
    }
  }

  Future<void> _bringUp() async {
    if (await FlutterForegroundTask.isAppOnForeground) return;
    FlutterForegroundTask.wakeUpScreen();
    FlutterForegroundTask.setOnLockScreenVisibility(true);
    FlutterForegroundTask.launchApp();
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      final kt = data['keyterms'];
      if (kt is String) _keyterms = kt; // main'den boost terimleri
      return;
    }
    if (data is! String) return;
    switch (data) {
      case 'pause':
        _wake?.stop();
        break;
      case 'resume':
        _wake?.start();
        break;
      case 'arm':
        _wake?.armForCommand();
        break;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _wake?.stop();
  }
}

class ForegroundWakeService {
  static void initPort() => FlutterForegroundTask.initCommunicationPort();

  static Future<void> startIfPermitted() async {
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sahin_wake',
        channelName: 'Şahin dinliyor',
        channelDescription: 'Şahin arka planda "Şahin" komutunu bekler.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );

    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.microphone],
      serviceId: 261,
      notificationTitle: 'Şahin aktif',
      notificationText: '"Şahin" de — seni dinliyorum',
      callback: wakeServiceCallback,
    );
  }

  static Future<bool> ensureOverlayPermission() async {
    if (await FlutterForegroundTask.canDrawOverlays) return true;
    await FlutterForegroundTask.openSystemAlertWindowSettings();
    return FlutterForegroundTask.canDrawOverlays;
  }

  /// Servisin Deepgram için kullanacağı boost terimleri (isimler+komutlar). main'den gönderilir.
  static void setKeyterms(String csv) =>
      FlutterForegroundTask.sendDataToTask({'keyterms': csv});

  static void pauseMic() => FlutterForegroundTask.sendDataToTask('pause');
  static void resumeMic() => FlutterForegroundTask.sendDataToTask('resume');
  static void armForCommand() => FlutterForegroundTask.sendDataToTask('arm');

  static Future<String?> takePendingCommand() async {
    final cmd = await FlutterForegroundTask.getData<String>(key: 'pending_command');
    if (cmd != null && cmd.trim().isNotEmpty) {
      await FlutterForegroundTask.removeData(key: 'pending_command');
      return cmd;
    }
    return null;
  }

  static Future<bool> takePendingCapture() async {
    final v = await FlutterForegroundTask.getData<bool>(key: 'pending_capture');
    if (v == true) {
      await FlutterForegroundTask.removeData(key: 'pending_capture');
      return true;
    }
    return false;
  }

  static Future<void> stop() => FlutterForegroundTask.stopService();
}
