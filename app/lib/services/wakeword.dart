import 'dart:convert';

import 'package:vosk_flutter_2/vosk_flutter_2.dart';

/// "Şahin" wake word — Vosk ile sürekli, cihazda, kayıtsız dinleme (SPEC Faz 9).
///
/// Vosk Türkçe modelini yükler, mikrofonu sürekli dinler. Bir cümlede "şahin"
/// geçtiğinde, sonrasındaki metni komut olarak callback'e verir ("Şahin annemi ara").
class WakeWordService {
  static const _modelAsset = 'assets/models/vosk-model-small-tr-0.3.zip';
  // "şahin" ve Vosk'un üretebileceği yakın yazımlar.
  static const _wakeWords = ['şahin', 'sahin', 'şahım', 'şahini', 'şahi'];

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  SpeechService? _speech;
  bool _ready = false;
  bool _running = false;

  bool get ready => _ready;
  bool get running => _running;

  /// Modeli yükler ve servisi hazırlar (ilk açılışta ~birkaç saniye, 36MB zip açılır).
  Future<void> init() async {
    if (_ready) return;
    final modelPath = await ModelLoader().loadFromAssets(_modelAsset);
    final model = await _vosk.createModel(modelPath);
    final recognizer = await _vosk.createRecognizer(model: model, sampleRate: 16000);
    _speech = await _vosk.initSpeechService(recognizer);
    _ready = true;
  }

  /// Her tam (final) sonuçta 'şahin' aranır; bulunursa sonrasındaki komut cb'ye verilir.
  void onWake(void Function(String command) cb) {
    _speech?.onResult().listen((json) {
      String text;
      try {
        text = (jsonDecode(json)['text'] ?? '').toString();
      } catch (_) {
        return;
      }
      text = text.toLowerCase().trim();
      if (text.isEmpty) return;
      final idx = _wakeIndex(text);
      if (idx < 0) return;
      // 'şahin' (ve eklerini) at, kalanı komut olarak ver.
      var cmd = text.substring(idx);
      cmd = cmd.replaceFirst(RegExp(r'^(şahin|sahin|şahım|şahini|şahi)\W*'), '').trim();
      cb(cmd);
    });
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
