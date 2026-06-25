import 'dart:ui';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'wakeword.dart';

/// Faz 10 — Arka plan wake word. Vosk dinleme SERVİSİN KENDİ isolate'ında çalışır
/// (TaskHandler), böylece uygulama swipe'lansa/kapatılsa bile dinleme sürer.
///
/// Komut/wake olunca:
///  - uygulama ön plandaysa → sendDataToMain ile mevcut _handleText akışına ver,
///  - arka planda/kapalıysa → komutu kalıcı kaydet (pending_command) + ekranı uyandır + app'i aç;
///    app açılınca bekleyen komutu işler.
///
/// KISIT: servis yalnızca uygulama ÖN PLANDAYKEN başlar (Android 14+ mic kuralı).
/// Reboot sonrası app bir kez açılmalı.

@pragma('vm:entry-point')
void wakeServiceCallback() {
  FlutterForegroundTask.setTaskHandler(WakeTaskHandler());
}

class WakeTaskHandler extends TaskHandler {
  WakeWordService? _wake;

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
      // Vosk bu isolate'ta çalışmazsa burada patlar — cihaz testinde görülür.
      FlutterForegroundTask.updateService(
        notificationTitle: 'Şahin',
        notificationText: 'Dinleme başlatılamadı (servis)',
      );
    }
  }

  /// Sadece "Şahin" duyuldu → komutu Whisper ile kaydetmesi için main'i tetikle (isabetli).
  Future<void> _onWake() async {
    if (await FlutterForegroundTask.isAppOnForeground) {
      FlutterForegroundTask.sendDataToMain({'capture': true});
    } else {
      await FlutterForegroundTask.saveData(key: 'pending_capture', value: true);
      await _bringUp();
    }
  }

  /// Komut hazır → ön plandaysa UI'a ver, değilse kaydet + app'i aç.
  Future<void> _onCommand(String command) async {
    if (await FlutterForegroundTask.isAppOnForeground) {
      FlutterForegroundTask.sendDataToMain({'cmd': command});
    } else {
      await FlutterForegroundTask.saveData(key: 'pending_command', value: command);
      await _bringUp();
    }
  }

  Future<void> _bringUp() async {
    if (await FlutterForegroundTask.isAppOnForeground) return;
    FlutterForegroundTask.wakeUpScreen();
    FlutterForegroundTask.setOnLockScreenVisibility(true);
    FlutterForegroundTask.launchApp();
  }

  /// UI'dan gelen mic kontrol mesajları (TTS/işleme/buton kaydı sırasında çakışma önleme).
  @override
  void onReceiveData(Object data) {
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
  /// main() içinde, runApp'tan önce.
  static void initPort() => FlutterForegroundTask.initCommunicationPort();

  /// İzinleri ister + mikrofon tipli FGS'yi başlatır (servis Vosk'u dinlemeye başlar).
  /// SADECE uygulama önplandayken çağır.
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
        autoRunOnBoot: false, // Android 14+ mic FGS BOOT'tan başlatılamaz
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

  /// launchApp için "diğer uygulamaların üzerinde göster" izni gerekir; yoksa ayarları açar.
  static Future<bool> ensureOverlayPermission() async {
    if (await FlutterForegroundTask.canDrawOverlays) return true;
    await FlutterForegroundTask.openSystemAlertWindowSettings();
    return FlutterForegroundTask.canDrawOverlays;
  }

  // Ana isolate → servis Vosk kontrolü (mesaj köprüsü).
  static void pauseMic() => FlutterForegroundTask.sendDataToTask('pause');
  static void resumeMic() => FlutterForegroundTask.sendDataToTask('resume');
  static void armForCommand() => FlutterForegroundTask.sendDataToTask('arm');

  /// Arka plandan açılınca bekleyen komutu çek (ve sil). Yoksa null.
  static Future<String?> takePendingCommand() async {
    final cmd = await FlutterForegroundTask.getData<String>(key: 'pending_command');
    if (cmd != null && cmd.trim().isNotEmpty) {
      await FlutterForegroundTask.removeData(key: 'pending_command');
      return cmd;
    }
    return null;
  }

  /// Arka planda "Şahin" duyulup açıldıysak: komutu Whisper ile kaydetmemiz gerekiyor mu?
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
