import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// TTS mp3 baytlarını çalar (audioplayers).
class TtsPlayer {
  final AudioPlayer _player = AudioPlayer();

  /// mp3 baytlarını çalar ve bitene kadar bekler.
  Future<void> playBytes(Uint8List bytes) async {
    await _player.stop();
    await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
    // Çalma bitene kadar bekle (UI durumu doğru olsun).
    await _player.onPlayerComplete.first;
  }

  void dispose() => _player.dispose();
}
