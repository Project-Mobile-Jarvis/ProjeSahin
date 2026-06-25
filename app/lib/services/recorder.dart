import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Mikrofon kaydı (record paketi). m4a/AAC olarak kaydeder (Groq Whisper kabul eder).
class Recorder {
  final AudioRecorder _rec = AudioRecorder();

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/jarvis_rec.m4a';
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1),
      path: path,
    );
  }

  /// Kaydı durdurur, dosya yolunu döner (yoksa null).
  Future<String?> stop() => _rec.stop();

  Future<bool> isRecording() => _rec.isRecording();

  /// Eller-serbest kayıt: başlatır, SESSİZLİK (VAD) ya da [maxDuration] dolunca otomatik durur.
  /// "Şahin" sonrası komutu butona basmadan kaydetmek için. Dosya yolunu döner.
  Future<String?> recordUntilSilence({
    Duration maxDuration = const Duration(seconds: 9),
    Duration silenceHold = const Duration(milliseconds: 1500),
    double silenceDb = -42.0, // bunun altı "sessizlik" (dBFS) — gevşek tutuldu (komutu kesmesin)
    Duration graceStart = const Duration(milliseconds: 900),
  }) async {
    await start();
    final completer = Completer<String?>();
    final t0 = DateTime.now();
    DateTime? silenceSince;
    StreamSubscription<Amplitude>? sub;
    Timer? maxTimer;

    Future<void> done() async {
      if (completer.isCompleted) return;
      await sub?.cancel();
      maxTimer?.cancel();
      completer.complete(await stop());
    }

    maxTimer = Timer(maxDuration, done);
    sub = _rec.onAmplitudeChanged(const Duration(milliseconds: 200)).listen((amp) {
      // İlk anlar: kullanıcı konuşmaya başlasın diye sessizliği sayma.
      if (DateTime.now().difference(t0) < graceStart) {
        silenceSince = null;
        return;
      }
      if (amp.current <= silenceDb) {
        silenceSince ??= DateTime.now();
        if (DateTime.now().difference(silenceSince!) >= silenceHold) done();
      } else {
        silenceSince = null; // ses var → sessizlik sayacı sıfırla
      }
    });

    return completer.future;
  }

  void dispose() => _rec.dispose();
}
