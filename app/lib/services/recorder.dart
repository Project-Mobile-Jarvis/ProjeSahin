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

  void dispose() => _rec.dispose();
}
