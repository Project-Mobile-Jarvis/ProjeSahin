import 'dart:ui';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'wakeword.dart';

/// Faz 10 — Arka plan wake word. Vosk dinleme SERVİSİN KENDİ isolate'ında çalışır
/// (uygulama swipe'lansa/kapatılsa bile sürer). Komut KAYDI ise ana isolate'ta yapılır
/// (record/path_provider arka plan isolate'ında çalışmıyor — Vosk hariç). Servis sadece
/// "Şahin"i algılar ve main'e sinyal verir:
///  - 'capture': sadece "Şahin" → main komutu kaydeder (Deepgram, isabetli).
///  - 'cmd': tek nefes "Şahin X" → X Vosk metni (hızlı).

@pragma('vm:entry-point')
void wakeServiceCallback() {
  FlutterForegroundTask.setTaskHandler(WakeTaskHandler());
}

class WakeTaskHandler extends TaskHandler {
  WakeWordService? _wake;
  bool _micBusy = false; // komut için Vosk geçici durduruldu mu
  DateTime? _pauseAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized();
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

  /// Sadece "Şahin" → main komutu Whisper/Deepgram ile kaydetsin (isabetli).
  Future<void> _onWake() async {
    if (await FlutterForegroundTask.isAppOnForeground) {
      FlutterForegroundTask.sendDataToMain({'capture': true});
    } else {
      await FlutterForegroundTask.saveData(key: 'pending_capture', value: true);
      await _bringUp();
    }
  }

  /// Tek nefes "Şahin X" (Vosk metni) veya WhatsApp onayı → main.
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

  @override
  void onReceiveData(Object data) {
    if (data is! String) return;
    switch (data) {
      case 'pause':
        _micBusy = true;
        _pauseAt = DateTime.now();
        _wake?.stop();
        break;
      case 'resume':
        _micBusy = false;
        _wake?.start();
        break;
      case 'arm':
        _wake?.armForCommand();
        break;
    }
  }

  /// Watchdog (her ~15sn): Vosk komut sonrası takılı kalırsa (resume kaybolursa) geri başlat.
  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_micBusy) {
      // 12 sn'den uzun "meşgul" → resume kaybolmuş say, toparla. Değilse komut sürüyor olabilir.
      if (_pauseAt != null && DateTime.now().difference(_pauseAt!).inSeconds > 6) {
        _micBusy = false;
      } else {
        return;
      }
    }
    final w = _wake;
    if (w != null && w.ready && !w.running) {
      w.start(); // dinleme durmuşsa geri aç
    }
  }

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
        eventAction: ForegroundTaskEventAction.repeat(4000), // watchdog tetiği (~4sn'de Vosk'u toparla)
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
