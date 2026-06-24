import 'dart:async';
import 'dart:convert';

import 'package:vosk_flutter_2/vosk_flutter_2.dart';

/// "Şahin" wake word — Vosk ile sürekli, cihazda, kayıtsız dinleme (SPEC Faz 9).
///
/// İki akış da desteklenir (Vosk sessizlikte cümleyi otomatik bitirir → tıklama yok):
///  - Tek nefes: "Şahin annemi ara" → komut = "annemi ara".
///  - İki aşama: "Şahin" → (komut beklenir) → "annemi ara" → komut = "annemi ara".
class WakeWordService {
  static const _modelAsset = 'assets/models/vosk-model-small-tr-0.3.zip';
  static const _wakeWords = ['şahin', 'sahin', 'şahım', 'şahini', 'şahi'];
  static final _wakeStrip = RegExp(r'^(şahin|sahin|şahım|şahini|şahi)\W*');

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  SpeechService? _speech;
  bool _ready = false;
  bool _running = false;

  bool _awaiting = false; // "şahin" duyuldu, komut bekleniyor
  Timer? _awaitTimer;
  void Function(String command)? _onCommand;
  void Function()? _onWake;

  bool get ready => _ready;
  bool get running => _running;

  Future<void> init() async {
    if (_ready) return;
    final modelPath = await ModelLoader().loadFromAssets(_modelAsset);
    final model = await _vosk.createModel(modelPath);
    final recognizer = await _vosk.createRecognizer(model: model, sampleRate: 16000);
    _speech = await _vosk.initSpeechService(recognizer);
    _ready = true;
  }

  /// [onCommand]: komut hazır olunca. [onWake]: sadece "şahin" duyulunca (komut bekleniyor).
  void listen({required void Function(String) onCommand, void Function()? onWake}) {
    _onCommand = onCommand;
    _onWake = onWake;
    _speech?.onResult().listen(_handleResult);
  }

  /// "Şahin" demeden doğrudan komut bekle — sesli onay sonrası otomatik dinleme için.
  /// (Sıradaki cümle, başında "Şahin" olmasa da komut olarak gelir.)
  void armForCommand() {
    _awaiting = true;
    _onWake?.call();
    _awaitTimer?.cancel();
    _awaitTimer = Timer(const Duration(seconds: 10), () => _awaiting = false);
  }

  void _handleResult(String json) {
    String text;
    try {
      text = (jsonDecode(json)['text'] ?? '').toString().toLowerCase().trim();
    } catch (_) {
      return;
    }
    if (text.isEmpty) return;

    // "Şahin" sonrası komut bekliyorduk → bu cümle komuttur.
    if (_awaiting) {
      _awaiting = false;
      _awaitTimer?.cancel();
      final cmd = text.replaceFirst(_wakeStrip, '').trim();
      if (cmd.isNotEmpty) _onCommand?.call(cmd);
      return;
    }

    final idx = _wakeIndex(text);
    if (idx < 0) return; // bu cümlede "şahin" yok → yok say
    final after = text.substring(idx).replaceFirst(_wakeStrip, '').trim();
    if (after.isNotEmpty) {
      _onCommand?.call(after); // tek nefes: "şahin annemi ara"
    } else {
      _awaiting = true; // sadece "şahin" → sıradaki cümleyi komut bekle
      _onWake?.call();
      _awaitTimer?.cancel();
      _awaitTimer = Timer(const Duration(seconds: 8), () => _awaiting = false);
    }
  }

  int _wakeIndex(String text) {
    var best = -1;
    for (final w in _wakeWords) {
      final i = text.indexOf(w);
      if (i >= 0 && (best < 0 || i < best)) best = i;
    }
    return best;
  }

  Future<void> start() async {
    if (!_ready || _running) return;
    await _speech?.start();
    _running = true;
  }

  Future<void> stop() async {
    if (!_running) return;
    await _speech?.stop();
    _running = false;
  }
}
