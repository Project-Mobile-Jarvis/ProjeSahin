import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';
import 'services/actions.dart';
import 'services/backend.dart';
import 'services/location.dart';
import 'services/player.dart';
import 'services/recorder.dart';
import 'services/foreground.dart';
import 'services/whatsapp.dart';

void main() {
  ForegroundWakeService.initPort(); // TaskHandler <-> UI iletişim portu (runApp'tan önce)
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

/// Sesli onay bekleyen WhatsApp mesajı.
class _PendingWa {
  final String phone;
  final String message;
  final String label;
  final DateTime at;
  _PendingWa(this.phone, this.message, this.label) : at = DateTime.now();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final Recorder _recorder = Recorder();
  final TtsPlayer _player = TtsPlayer();
  final BackendClient _backend = BackendClient();
  final LocationService _location = LocationService();
  final DeviceActions _actions = DeviceActions();
  final WhatsAppService _wa = WhatsAppService();

  AssistantState _state = AssistantState.idle;
  String _status = 'Hazır — konuşmak için bas';
  final List<_ChatMsg> _messages = [];
  final ScrollController _scroll = ScrollController();
  _PendingWa? _pendingWa; // sesli onay bekleyen WhatsApp mesajı
  int _waAttempts = 0; // belirsiz onay yanıtı sayacı (sonsuz döngüyü önler)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onServiceData); // servis → UI komut köprüsü
    _location.start(); // GPS izni + konum akışını ısıt
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Permission.microphone.request();
    // Faz 10: dinleme SERVİS isolate'ında — mikrofon tipli FGS başlat (swipe'tan sağ çıkar).
    try {
      await ForegroundWakeService.startIfPermitted();
      await ForegroundWakeService.ensureOverlayPermission();
    } catch (e) {
      debugPrint('JARVIS foreground servis hata: $e');
    }
    await _consumePending(); // launchApp ile açıldıysak bekleyen komutu işle
    _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
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

  /// Servis isolate'ından (arka plan Vosk) ön plandayken gelen sinyal:
  /// - 'cmd': tek nefes "Şahin X" → X Vosk metni (hızlı).
  /// - 'capture': sadece "Şahin" → komutu Whisper ile kaydet (isabetli).
  void _onServiceData(Object data) {
    if (_busy || _state == AssistantState.recording) return;
    if (data is! Map) return;
    if (data['cmd'] is String) {
      _handleText(data['cmd'] as String);
    } else if (data['capture'] == true) {
      _captureCommand();
    }
  }

  /// Arka plandan/kapalıdan açıldıysak servisin bıraktığı bekleyen işi yap.
  Future<void> _consumePending() async {
    if (_busy || _state == AssistantState.recording) return;
    final cmd = await ForegroundWakeService.takePendingCommand();
    if (cmd != null && mounted) {
      await _handleText(cmd);
      return;
    }
    if (await ForegroundWakeService.takePendingCapture() && mounted) {
      await _captureCommand();
    }
  }

  /// "Şahin" sonrası komutu butona basmadan kaydeder → Whisper (isabetli) → işler.
  /// Sessizlikte otomatik durur (VAD).
  Future<void> _captureCommand() async {
    if (_busy || _state == AssistantState.recording) return;
    ForegroundWakeService.pauseMic(); // servis Vosk mic'i bıraksın
    await Future.delayed(const Duration(milliseconds: 300));
    if (!await _recorder.hasPermission()) {
      ForegroundWakeService.resumeMic();
      return;
    }
    _set(AssistantState.recording, 'Şahin dinliyor — söyle 🎤');
    try {
      final path = await _recorder.recordUntilSilence();
      if (path == null) {
        _set(AssistantState.idle, 'Duyamadım, tekrar dene');
        return;
      }
      _set(AssistantState.thinking, 'Yazıya çeviriyorum…');
      final text = await _backend.stt(path, prompt: await _actions.sttBiasPrompt());
      debugPrint('JARVIS STT(capture): "$text"');
      if (text.trim().isEmpty) {
        _set(AssistantState.idle, 'Bir şey duyamadım, tekrar dene');
        return;
      }
      await _handleText(text);
    } catch (e, st) {
      debugPrint('JARVIS capture hata: $e\n$st');
      _set(AssistantState.error, 'Hata: ${_short(e)}');
    } finally {
      ForegroundWakeService.resumeMic();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _consumePending();
  }

  Future<void> _startRecording() async {
    ForegroundWakeService.pauseMic(); // servis Vosk mic'i bıraksın (buton kaydı için)
    await Future.delayed(const Duration(milliseconds: 350)); // mic serbest kalsın
    if (!await _recorder.hasPermission()) {
      await Permission.microphone.request();
      if (!await _recorder.hasPermission()) {
        _set(AssistantState.error, 'Mikrofon izni gerekli');
        ForegroundWakeService.resumeMic();
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
      ForegroundWakeService.resumeMic();
      return;
    }
    try {
      _set(AssistantState.thinking, 'Yazıya çeviriyorum…');
      final text = await _backend.stt(path, prompt: await _actions.sttBiasPrompt());
      debugPrint('JARVIS STT(button): "$text"');
      if (text.trim().isEmpty) {
        _set(AssistantState.idle, 'Bir şey duyamadım, tekrar dene');
        return;
      }
      await _handleText(text); // mic'i kendisi yönetir (pause/resume)
    } catch (e, st) {
      debugPrint('JARVIS hata: $e\n$st');
      _set(AssistantState.error, 'Hata: ${_short(e)}');
    } finally {
      ForegroundWakeService.resumeMic(); // her durumda servis Vosk geri (idempotent)
    }
  }

  /// Metni (buton STT'sinden veya wake word'den) işler: /chat → sesli cevap → cihaz aksiyonu.
  Future<void> _handleText(String text) async {
    ForegroundWakeService.pauseMic(); // işleme + TTS sırasında servis Vosk sussun (self-trigger yok)
    try {
      // WhatsApp onayı bekleniyorsa bu sözü onay/iptal olarak değerlendir.
      if (_pendingWa != null && await _handleWaConfirmation(text)) return;

      _addMsg('Sen', text, user: true);
      _set(AssistantState.thinking, 'Düşünüyorum…');
      final pos = _location.last;
      final result =
          await _backend.chat(text, lat: pos?.latitude, lng: pos?.longitude);

      if (result.action == 'send_whatsapp') {
        // Onay cümlesini _startWhatsAppFlow kendisi üretir + seslendirir (Gemini reply'ına bağlı değil).
        await _startWhatsAppFlow(result.args);
      } else {
        // Önce kısa sesli cevap, sonra cihaz aksiyonu (Maps/dialer uygulamayı öne alabilir).
        if (result.reply.trim().isNotEmpty) {
          _addMsg('Şahin', result.reply, user: false);
          _set(AssistantState.speaking, 'Cevaplıyorum…');
          await _speak(result.reply);
        }
        final note = await _actions.dispatch(result.action, result.args);
        if (note != null && note.trim().isNotEmpty) {
          _addMsg('Şahin', note, user: false);
          await _speak(note);
        }
      }
      _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
    } catch (e, st) {
      debugPrint('JARVIS hata: $e\n$st');
      _addMsg('Şahin', 'Hata: ${_short(e)}', user: false, error: true);
      _set(AssistantState.error, 'Hata: ${_short(e)}');
    } finally {
      // Onay bekleniyorsa "Şahin"siz komut dinle; her hâlükârda servis Vosk'u geri aç.
      if (_pendingWa != null) ForegroundWakeService.armForCommand();
      ForegroundWakeService.resumeMic();
    }
  }

  /// Metni seslendirir (TTS → çal). Hata olursa sessiz geçer.
  Future<void> _speak(String text) async {
    try {
      final audio = await _backend.tts(text);
      await _player.playBytes(audio);
    } catch (_) {}
  }

  /// send_whatsapp: izni kontrol et, kişiyi numaraya çöz, sesli onay bekle.
  /// (Gemini'nin reply'ı zaten "onaylıyor musun?" diye sordu; burada onayı bekliyoruz.)
  Future<void> _startWhatsAppFlow(Map<String, dynamic> args) async {
    final target = (args['target'] ?? '').toString().trim();
    final spokenText = (args['text'] ?? '').toString().trim();
    final includeLoc = args['include_location'] == true;
    if (target.isEmpty || spokenText.isEmpty) return;

    if (!await _wa.isEnabled()) {
      const msg =
          'WhatsApp mesajını senin için göndermem için bir kez erişilebilirlik iznini açman gerekiyor. '
          'Ayarları açıyorum; listeden Şahin\'i bulup aç, sonra tekrar dene.';
      _addMsg('Şahin', msg, user: false);
      _set(AssistantState.speaking, 'Cevaplıyorum…');
      await _speak(msg);
      await _wa.openSettings();
      return;
    }

    final phone = await _actions.resolveWhatsAppNumber(target);
    if (phone == null) {
      final msg = '$target\'ı rehberde bulamadım, mesajı gönderemiyorum.';
      _addMsg('Şahin', msg, user: false);
      _set(AssistantState.speaking, 'Cevaplıyorum…');
      await _speak(msg);
      return;
    }

    // Gönderilecek tam metin (gerekirse konum linkiyle). Sesli okurken linki okumayız.
    var message = spokenText;
    if (includeLoc) {
      final pos = _location.last;
      if (pos != null) {
        message +=
            '\nKonum: https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
      }
    }

    _pendingWa = _PendingWa(phone, message, target);
    _waAttempts = 0;
    // (_handleText finally'si _pendingWa varsa servisi "Şahin"siz komut beklemeye arm eder.)
    // Onay cümlesini UYGULAMA üretir ve seslendirir (her zaman okunsun diye).
    final confirm = includeLoc
        ? '$target\'a "$spokenText" yazıp konumu da ekliyorum. Göndereyim mi?'
        : '$target\'a "$spokenText" gönderiyorum. Onaylıyor musun?';
    _addMsg('Şahin', '$confirm\n(mikrofon açık — "gönder" / "iptal")', user: false);
    _set(AssistantState.speaking, 'Cevaplıyorum…');
    await _speak(confirm);
  }

  /// Onay bekleyen WhatsApp mesajı için yanıtı değerlendirir.
  /// true: yanıt tüketildi (evet/hayır). false: belirsiz → normal komut gibi işlensin.
  Future<bool> _handleWaConfirmation(String text) async {
    final pend = _pendingWa!;
    if (DateTime.now().difference(pend.at).inSeconds > 90) {
      _pendingWa = null; // onay penceresi kapandı
      _waAttempts = 0;
      return false;
    }
    final t = text.toLowerCase();
    const yes = [
      'evet', 'gönder', 'gonder', 'onay', 'yolla', 'olur', 'tamam',
      'tabii', 'tabi', 'peki', 'okey', 'gönderebilirsin'
    ];
    const no = [
      'iptal', 'vazgeç', 'vazgec', 'hayır', 'hayir', 'dur',
      'boş ver', 'bos ver', 'gerek yok', 'istemiyorum', 'yok'
    ];
    final isYes = yes.any((w) => t.contains(w));
    final isNo = no.any((w) => t.contains(w));

    if (isYes && !isNo) {
      _pendingWa = null;
      _waAttempts = 0;
      _addMsg('Sen', text, user: true);
      final ok = await _wa.sendWhatsApp(pend.phone, pend.message);
      final msg = ok
          ? '${pend.label}\'a gönderiyorum.'
          : 'Gönderemedim — erişilebilirlik izni kapalı olabilir.';
      _addMsg('Şahin', msg, user: false);
      _set(AssistantState.speaking, 'Cevaplıyorum…');
      await _speak(msg);
      _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
      return true;
    }

    if (isNo) {
      _pendingWa = null;
      _waAttempts = 0;
      _addMsg('Sen', text, user: true);
      const msg = 'Tamam, göndermekten vazgeçtim.';
      _addMsg('Şahin', msg, user: false);
      _set(AssistantState.speaking, 'Cevaplıyorum…');
      await _speak(msg);
      _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
      return true;
    }

    // Belirsiz yanıt: /chat'e DÜŞME (yoksa Gemini send_whatsapp'ı tekrar çağırır → döngü).
    _addMsg('Sen', text, user: true);
    _waAttempts++;
    if (_waAttempts < 2) {
      // (_pendingWa duruyor → _handleText finally'si tekrar arm eder.)
      const msg = 'Anlayamadım — göndereyim mi? "gönder" ya da "iptal" de.';
      _addMsg('Şahin', msg, user: false);
      _set(AssistantState.speaking, 'Cevaplıyorum…');
      await _speak(msg);
      _set(AssistantState.idle, 'Hazır');
      return true;
    }
    // İkinci belirsizlikte pes et — iptal.
    _pendingWa = null;
    _waAttempts = 0;
    const msg = 'Tamam, şimdilik göndermiyorum.';
    _addMsg('Şahin', msg, user: false);
    _set(AssistantState.speaking, 'Cevaplıyorum…');
    await _speak(msg);
    _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
    return true;
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
