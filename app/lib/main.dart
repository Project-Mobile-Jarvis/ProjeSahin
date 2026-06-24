import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';
import 'services/actions.dart';
import 'services/backend.dart';
import 'services/location.dart';
import 'services/player.dart';
import 'services/recorder.dart';
import 'services/wakeword.dart';

void main() {
  runApp(const SahinApp());
}

class SahinApp extends StatelessWidget {
  const SahinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Şahin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00BFA6),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1116),
      ),
      home: const HomePage(),
    );
  }
}

enum AssistantState { idle, recording, thinking, speaking, error }

/// Ekrandaki tek bir sohbet balonu (kullanıcı veya Şahin).
class _ChatMsg {
  final String who;
  final String text;
  final bool user;
  final bool error;
  _ChatMsg(this.who, this.text, this.user, this.error);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Recorder _recorder = Recorder();
  final TtsPlayer _player = TtsPlayer();
  final BackendClient _backend = BackendClient();
  final LocationService _location = LocationService();
  final DeviceActions _actions = DeviceActions();
  final WakeWordService _wake = WakeWordService();

  AssistantState _state = AssistantState.idle;
  String _status = 'Hazır — konuşmak için bas';
  final List<_ChatMsg> _messages = [];
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _location.start(); // GPS izni + konum akışını ısıt
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Permission.microphone.request();
    await _initWake();
  }

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy =>
      _state == AssistantState.thinking || _state == AssistantState.speaking;

  Future<void> _onMicPressed() async {
    if (_busy) return;
    if (_state == AssistantState.recording) {
      await _processRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _initWake() async {
    try {
      _set(_state, 'Şahin hazırlanıyor…');
      await _wake.init();
      _wake.listen(onCommand: _onWakeCommand, onWake: _onWakeListening);
      await _wake.start();
      _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
    } catch (e) {
      debugPrint('JARVIS wake init hata: $e');
      _set(AssistantState.idle, 'Hazır — konuşmak için bas');
    }
  }

  /// Sadece "şahin" duyuldu → komut bekleniyor. Vosk dinlemeye DEVAM eder (durdurma yok);
  /// sıradaki cümle (sustuğunda otomatik biter) komut olarak gelecek.
  void _onWakeListening() {
    if (_busy || _state == AssistantState.recording) return;
    _set(AssistantState.idle, 'Şahin dinliyor — komutunu söyle 🎤');
  }

  /// Komut hazır (tek nefes "şahin X" ya da "şahin" sonrası ayrı cümle) → işle.
  Future<void> _onWakeCommand(String command) async {
    if (_busy || _state == AssistantState.recording) return;
    await _wake.stop(); // işleme + TTS sırasında kapat (self-trigger yok)
    await _handleText(command);
    await _wake.start();
  }

  Future<void> _startRecording() async {
    await _wake.stop(); // buton kaydı sırasında Vosk mic'i bıraksın
    if (!await _recorder.hasPermission()) {
      await Permission.microphone.request();
      if (!await _recorder.hasPermission()) {
        _set(AssistantState.error, 'Mikrofon izni gerekli');
        await _wake.start();
        return;
      }
    }
    await _recorder.start();
    _set(AssistantState.recording, 'Dinliyorum… (bitince bas)');
  }

  Future<void> _processRecording() async {
    final path = await _recorder.stop();
    if (path == null) {
      _set(AssistantState.error, 'Kayıt alınamadı');
      await _wake.start();
      return;
    }
    try {
      _set(AssistantState.thinking, 'Yazıya çeviriyorum…');
      final text = await _backend.stt(path);
      if (text.trim().isEmpty) {
        _set(AssistantState.idle, 'Bir şey duyamadım, tekrar dene');
        return;
      }
      await _handleText(text);
    } catch (e, st) {
      debugPrint('JARVIS hata: $e\n$st');
      _set(AssistantState.error, 'Hata: ${_short(e)}');
    } finally {
      await _wake.start(); // buton akışı bitince wake'i geri aç
    }
  }

  /// Metni (buton STT'sinden veya wake word'den) işler: /chat → sesli cevap → cihaz aksiyonu.
  Future<void> _handleText(String text) async {
    _addMsg('Sen', text, user: true);
    try {
      _set(AssistantState.thinking, 'Düşünüyorum…');
      final pos = _location.last;
      final result =
          await _backend.chat(text, lat: pos?.latitude, lng: pos?.longitude);

      // Önce kısa sesli cevap, sonra cihaz aksiyonu (Maps/dialer uygulamayı öne alabilir).
      if (result.reply.trim().isNotEmpty) {
        _addMsg('Şahin', result.reply, user: false);
        _set(AssistantState.speaking, 'Cevaplıyorum…');
        final audio = await _backend.tts(result.reply);
        await _player.playBytes(audio);
      }
      final note = await _actions.dispatch(result.action, result.args);
      if (note != null && note.trim().isNotEmpty) {
        _addMsg('Şahin', note, user: false);
        try {
          final audio = await _backend.tts(note);
          await _player.playBytes(audio);
        } catch (_) {}
      }
      _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
    } catch (e, st) {
      debugPrint('JARVIS hata: $e\n$st');
      _addMsg('Şahin', 'Hata: ${_short(e)}', user: false, error: true);
      _set(AssistantState.error, 'Hata: ${_short(e)}');
    }
  }

  /// Sohbete bir balon ekler ve en alta kaydırır.
  void _addMsg(String who, String text, {required bool user, bool error = false}) {
    if (!mounted) return;
    setState(() => _messages.add(_ChatMsg(who, text, user, error)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _short(Object e) {
    final s = e.toString();
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  void _set(AssistantState s, String status) {
    if (!mounted) return;
    setState(() {
      _state = s;
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Şahin'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!Config.isConfigured)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'API_KEY verilmedi. --dart-define=API_KEY=... ile çalıştır.',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              Expanded(
                child: _messages.isEmpty
                    ? const Center(
                        child: Text(
                          '"Şahin" de ya da mikrofona bas 🎤',
                          style: TextStyle(color: Colors.white24),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final m = _messages[i];
                          return _bubble(
                            m.who,
                            m.text,
                            m.user ? Alignment.centerRight : Alignment.centerLeft,
                            m.error
                                ? const Color(0xFF3A1E1E)
                                : (m.user
                                    ? const Color(0xFF1E2730)
                                    : const Color(0xFF13322E)),
                          );
                        },
                      ),
              ),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _state == AssistantState.error
                      ? Colors.redAccent
                      : Colors.white70,
                ),
              ),
              const SizedBox(height: 20),
              Center(child: _micButton()),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _micButton() {
    final recording = _state == AssistantState.recording;
    final color = recording ? Colors.redAccent : const Color(0xFF00BFA6);
    return GestureDetector(
      onTap: _onMicPressed,
      child: Container(
        width: 110,
        height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: _busy ? 0.25 : 0.9),
          boxShadow: [
            BoxShadow(
                color: color.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 2),
          ],
        ),
        child: _busy
            ? const Padding(
                padding: EdgeInsets.all(34),
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
              )
            : Icon(recording ? Icons.stop : Icons.mic, size: 48, color: Colors.white),
      ),
    );
  }

  Widget _bubble(String who, String text, Alignment align, Color bg) {
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(who, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            const SizedBox(height: 3),
            Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}
