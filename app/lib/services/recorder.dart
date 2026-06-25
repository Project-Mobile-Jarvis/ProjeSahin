import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Mikrofon kaydı (record paketi). m4a/AAC olarak kaydeder (Groq Whisper kabul eder).
class Recorder {
  final AudioRecorder _rec = AudioRecorder();
  Future<void> Function()? _vadDone; // aktif VAD kaydını dışarıdan erken bitirmek için

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

  /// Aktif recordUntilSilence kaydını hemen bitirir (kullanıcı butona basınca).
  Future<void> stopEarly() async => _vadDone?.call();

  /// Eller-serbest kayıt: başlatır, kişi SUSUNCA (uyarlamalı VAD) ya da [maxDuration]
  /// dolunca otomatik durur. Eşik sabit değil — konuşma ZİRVESİNİN belli bir alt sınırına
  /// düşünce "sustu" sayar (cihaz/ortam ölçeğinden bağımsız çalışır). Dosya yolunu döner.
  Future<String?> recordUntilSilence({
    Duration maxDuration = const Duration(seconds: 7),
    Duration silenceHold = const Duration(milliseconds: 1200),
    Duration graceStart = const Duration(milliseconds: 600),
    double dropBelowPeak = 16.0, // konuşma zirvesinin bu kadar dB altı = sessizlik
  }) async {
    await start();
    final completer = Completer<String?>();
    final t0 = DateTime.now();
    DateTime? silenceSince;
    double peak = -160.0;
    bool heardSpeech = false;
    StreamSubscription<Amplitude>? sub;
    Timer? maxTimer;

    Future<void> done() async {
      if (completer.isCompleted) return;
      await sub?.cancel();
      maxTimer?.cancel();
      _vadDone = null;
      completer.complete(await stop());
    }

    _vadDone = done;
    maxTimer = Timer(maxDuration, done);
    sub = _rec.onAmplitudeChanged(const Duration(milliseconds: 150)).listen((amp) {
      final c = amp.current;
      if (c > peak) peak = c;
      if (c > -35) heardSpeech = true; // konuşma seviyesi görüldü
      debugPrint('VAD amp=${c.toStringAsFixed(1)} peak=${peak.toStringAsFixed(1)} speech=$heardSpeech');
      if (DateTime.now().difference(t0) < graceStart) return;
      final isSilence = heardSpeech && c < (peak - dropBelowPeak);
      if (isSilence) {
        silenceSince ??= DateTime.now();
        if (DateTime.now().difference(silenceSince!) >= silenceHold) done();
      } else {
        silenceSince = null;
      }
    });

    return completer.future;
  }

  void dispose() => _rec.dispose();
}
