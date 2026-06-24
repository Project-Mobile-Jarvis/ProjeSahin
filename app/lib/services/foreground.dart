import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Faz 10 — Arka plan wake word. Mikrofon tipli foreground servis SÜRECİ canlı tutar;
/// Vosk dinleme ANA isolate'ta sürdüğü için uygulama arka planda/ekran kapalıyken de
/// "Şahin" duyulmaya devam eder. (Vosk zaten native dinliyor; arka plan isolate'ı kırılgan
/// olduğundan ondan kaçınıldı — servis yalnızca process önceliğini yükseltir + kalıcı bildirim.)
///
/// KISIT: servis yalnızca uygulama ÖN PLANDAYKEN başlatılabilir (Android 14+ mic kuralı).
/// Reboot sonrası uygulama bir kez açılmalı.

@pragma('vm:entry-point')
void wakeServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

/// Servis sadece process'i canlı tutar; iş mantığı (Vosk) ana isolate'ta.
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class ForegroundWakeService {
  /// main() içinde, runApp'tan önce çağrılır.
  static void initPort() => FlutterForegroundTask.initCommunicationPort();

  /// İzinleri ister + mikrofon tipli FGS'yi başlatır. SADECE uygulama önplandayken çağır.
  static Future<void> startIfPermitted() async {
    // Kalıcı bildirim izni (Android 13+).
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    // Pil optimizasyonu muafiyeti (Samsung/OEM servisi öldürmesin).
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
        eventAction: ForegroundTaskEventAction.nothing(), // periyodik tetik yok; Vosk stream sürer
        autoRunOnBoot: false, // Android 14+ mic FGS BOOT'tan başlatılamaz
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

  /// Arka plandaysa ekranı uyandırıp uygulamayı öne getirir (overlay izni gerekir).
  static Future<void> bringToFrontIfBackground() async {
    if (await FlutterForegroundTask.isAppOnForeground) return;
    FlutterForegroundTask.wakeUpScreen();
    FlutterForegroundTask.setOnLockScreenVisibility(true);
    FlutterForegroundTask.launchApp();
  }

  /// launchApp için "diğer uygulamaların üzerinde göster" izni gerekir; yoksa ayarları açar.
  static Future<bool> ensureOverlayPermission() async {
    if (await FlutterForegroundTask.canDrawOverlays) return true;
    await FlutterForegroundTask.openSystemAlertWindowSettings();
    return FlutterForegroundTask.canDrawOverlays;
  }

  static Future<void> stop() => FlutterForegroundTask.stopService();
}
