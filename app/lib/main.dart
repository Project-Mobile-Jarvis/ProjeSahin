import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';
import 'services/actions.dart';
import 'services/backend.dart';
import 'services/location.dart';
import 'services/player.dart';
import 'services/recorder.dart';

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

  AssistantState _state = AssistantState.idle;
  String _status = 'Hazır — konuşmak için bas';
  String _transcript = '';
  String _reply = '';
  String _action = '';

  @override
  void initState() {
    super.initState();
    Permission.microphone.request();
    _location.start(); // GPS izni + konum akışını ısıt
  }

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
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

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      await Permission.microphone.request();
      if (!await _recorder.hasPermission()) {
        _set(AssistantState.error, 'Mikrofon izni gerekli');
        return;
      }
    }
    await _recorder.start();
    _set(AssistantState.recording, 'Dinliyorum… (bitince bas)');
    setState(() {
      _transcript = '';
      _reply = '';
      _action = '';
    });
  }

  Future<void> _processRecording() async {
    final path = await _recorder.stop();
    if (path == null) {
      _set(AssistantState.error, 'Kayıt alınamadı');
      return;
    }
    try {
      _set(AssistantState.thinking, 'Yazıya çeviriyorum…');
      final text = await _backend.stt(path);
      setState(() => _transcript = text);
      if (text.trim().isEmpty) {
        _set(AssistantState.idle, 'Bir şey duyamadım, tekrar dene');
        return;
      }

      _set(AssistantState.thinking, 'Düşünüyorum…');
      final pos = _location.last;
      final result =
          await _backend.chat(text, lat: pos?.latitude, lng: pos?.longitude);
      setState(() {
        _reply = result.reply;
        _action = result.action;
      });

      // Önce kısa sesli cevap, sonra cihaz aksiyonu (Maps/dialer uygulamayı öne alabilir).
      if (result.reply.trim().isNotEmpty) {
        _set(AssistantState.speaking, 'Cevaplıyorum…');
        final audio = await _backend.tts(result.reply);
        await _player.playBytes(audio);
      }
      await _actions.dispatch(result.action, result.args);
      _set(AssistantState.idle, 'Hazır — konuşmak için bas');
    } catch (e, st) {
      debugPrint('JARVIS hata: $e\n$st');
      _set(AssistantState.error, 'Hata: ${_short(e)}');
    }
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
              const Spacer(),
              if (_transcript.isNotEmpty)
                _bubble('Sen', _transcript, Alignment.centerRight,
                    const Color(0xFF1E2730)),
              if (_reply.isNotEmpty)
                _bubble('Şahin', _reply, Alignment.centerLeft,
                    const Color(0xFF13322E)),
              if (_action.isNotEmpty && _action != 'chat_reply')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('aksiyon: $_action',
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              const Spacer(),
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
