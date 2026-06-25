import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'services/actions.dart';
import 'services/backend.dart';
import 'services/location.dart';
import 'services/native_mic.dart';
import 'services/player.dart';
import 'services/whatsapp.dart';

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
    NativeMic.commands().listen(_onNativeCommand); // native servis → komut metni (ön plan)
    _location.start(); // GPS izni + konum akışını ısıt
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Permission.microphone.request();
    // Arka plandan öne getirme için "diğer uygulamaların üzerinde göster" izni (best-effort).
    if (!await Permission.systemAlertWindow.isGranted) {
      await Permission.systemAlertWindow.request();
    }
    // Faz 11: mic'in TEK sahibi NATIVE servis (Vosk wake + komut). Activity ön plandayken başlat.
    try {
      await NativeMic.start(
        backend: Config.backendUrl,
        apiKey: Config.apiKey,
        keyterms: await _actions.sttKeyterms(),
      );
    } catch (e) {
      debugPrint('JARVIS native mic hata: $e');
    }
    await _consumePending(); // native arka planda açtıysa bekleyen komutu işle
    _set(AssistantState.idle, 'Hazır — "Şahin" de ya da bas 🎤');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy =>
      _state == AssistantState.thinking || _state == AssistantState.speaking;

  /// Buton: native servise "wake beklemeden komutu kaydet" der; sonuç komut akışından gelir.
  Future<void> _onMicPressed() async {
    if (_busy || _state == AssistantState.recording) return;
    _set(AssistantState.recording, 'Dinliyorum… söyle');
    await NativeMic.captureNow();
  }

  /// Native servisin (ön plan) çözdüğü komut metni → işle.
  void _onNativeCommand(String text) {
    if (_busy) return;
    _handleText(text);
  }

  /// Native arka planda açtıysa SharedPreferences'a yazdığı bekleyen komutu işle.
  Future<void> _consumePending() async {
    if (_busy) return;
    final prefs = await SharedPreferences.getInstance();
    final cmd = prefs.getString('pending_command');
    if (cmd != null && cmd.trim().isNotEmpty) {
      await prefs.remove('pending_command');
      if (mounted) await _handleText(cmd);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _consumePending();
  }

  /// Metni (native komut veya buton) işler: /chat → sesli cevap → cihaz aksiyonu.
  Future<void> _handleText(String text) async {
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
      // Onay bekleniyorsa: "Şahin"siz onay yanıtı (evet/iptal) için native'i elle tetikle.
      if (_pendingWa != null) NativeMic.captureNow();
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
    // (_handleText finally'si _pendingWa varsa native'i onay yanıtı için tetikler.)
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
      // (_pendingWa duruyor → _handleText finally'si tekrar tetikler.)
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
