import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

/// Backend'den gelen aksiyon JSON'unu telefonda uygular (SPEC Faz 6).
/// Cihaz tool'ları: navigate_to, make_call, set_alarm, open_app.
class DeviceActions {
  String? _keyterms;

  /// STT boost terimleri (Deepgram keyterm / Whisper prompt): komut kelimeleri + rehber isimleri.
  /// "Osman", "Valide" gibi isimlerin doğru yazılması için. Virgüllü liste. Bir kez kurulur (cache).
  Future<String> sttKeyterms() async {
    if (_keyterms != null) return _keyterms!;
    final terms = <String>{
      'ara', 'telefon', 'mesaj', 'gönder', 'yaz', 'WhatsApp', 'alarm', 'kur',
      'navigasyon', 'başlat', 'götür', 'eve', 'en yakın', 'hava durumu',
      'anne', 'baba', 'peder', 'valide', 'kardeş', 'abi', 'abla', 'eş',
      'dede', 'anneanne', 'teyze', 'hala', 'amca', 'dayı',
    };
    try {
      final status = await Permission.contacts.request();
      if (status.isGranted) {
        final contacts =
            await FlutterContacts.getAll(properties: {ContactProperty.name});
        for (final c in contacts) {
          final dn = (c.displayName ?? '').trim();
          if (dn.isEmpty) continue;
          final first = dn.split(RegExp(r'\s+')).first;
          if (first.length >= 2) terms.add(first);
          if (terms.length >= 90) break;
        }
      }
    } catch (_) {}
    _keyterms = terms.join(',');
    return _keyterms!;
  }

  /// Aksiyonu uygular. Cihaz aksiyonu yoksa (chat_reply vb.) sessizce geçer.
  /// Döner: kullanıcı aksiyon hakkında bilgilendirilecekse kısa not (yoksa null).
  Future<String?> dispatch(String action, Map<String, dynamic> args) async {
    switch (action) {
      case 'navigate_to':
        return _navigate(args);
      case 'make_call':
        return _call(args);
      case 'set_alarm':
        return _alarm(args);
      case 'open_app':
        return _openApp(args);
      default:
        return null; // chat_reply, search_places sonucu vb. → cihaz aksiyonu yok
    }
  }

  Future<String?> _navigate(Map<String, dynamic> args) async {
    final lat = args['lat'];
    final lng = args['lng'];
    Uri uri;
    if (lat != null && lng != null) {
      uri = Uri.parse('google.navigation:q=$lat,$lng');
    } else {
      final q = Uri.encodeComponent((args['query'] ?? '').toString());
      uri = Uri.parse('google.navigation:q=$q');
    }
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return null;
    // Yedek: Google Maps arama linki
    final q = (args['query'] ?? '$lat,$lng').toString();
    await launchUrl(
      Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(q)}'),
      mode: LaunchMode.externalApplication,
    );
    return null;
  }

  Future<String?> _call(Map<String, dynamic> args) async {
    final target = (args['target'] ?? '').toString().trim();
    debugPrint('JARVIS make_call: target="$target"');
    if (target.isEmpty) return null;
    var number = await _resolveContact(target);
    number ??= RegExp(r'\d{3,}').hasMatch(target) ? target : null;
    if (number == null) return '$target rehberde bulunamadı';
    final clean = number.replaceAll(RegExp(r'[^\d+]'), '');
    // Doğrudan ara (CALL_PHONE izniyle). İzin yoksa çeviriciyi aç (yedek).
    final perm = await Permission.phone.request();
    if (perm.isGranted) {
      await AndroidIntent(action: 'android.intent.action.CALL', data: 'tel:$clean').launch();
    } else {
      await launchUrl(Uri(scheme: 'tel', path: clean), mode: LaunchMode.externalApplication);
    }
    return null;
  }

  /// Rehberden kişiyi çözüp WhatsApp için numara (sadece rakam, ülke kodlu) döndürür. Yoksa null.
  Future<String?> resolveWhatsAppNumber(String target) async {
    var number = await _resolveContact(target);
    number ??= RegExp(r'\d{7,}').hasMatch(target) ? target : null;
    if (number == null) return null;
    return _normalizeMsisdn(number);
  }

  /// wa.me için normalize: sadece rakam, ülke kodlu (+ ve baştaki 0 atılır).
  /// Türkiye varsayımı: 05XXXXXXXXX → 905XXXXXXXXX, 5XXXXXXXXX → 905XXXXXXXXX.
  String _normalizeMsisdn(String raw) {
    final plus = raw.trim().startsWith('+');
    final d = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (plus) return d; // zaten uluslararası verilmiş
    if (d.startsWith('00')) return d.substring(2);
    if (d.startsWith('0')) return '90${d.substring(1)}';
    if (d.length == 10 && d.startsWith('5')) return '90$d';
    return d;
  }

  // Akrabalık eş anlamlıları: kişi rehberde örn. "Annem" kayıtlıysa "valide" de eşleşsin.
  static const Map<String, List<String>> _kinship = {
    'anne': ['anne', 'annem', 'valide', 'anneciğim'],
    'annem': ['anne', 'annem', 'valide', 'anneciğim'],
    'valide': ['valide', 'anne', 'annem', 'anneciğim'],
    'baba': ['baba', 'babam', 'peder'],
    'babam': ['baba', 'babam', 'peder'],
    'kardeş': ['kardeş', 'kardeşim'],
    'abi': ['abi', 'abim', 'ağabey'],
    'abla': ['abla', 'ablam'],
    'eş': ['eş', 'eşim', 'karım', 'kocam', 'hayatım'],
  };

  Future<String?> _resolveContact(String name) async {
    try {
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        debugPrint('JARVIS contacts: izin yok ($status)');
        return null;
      }
      final contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      final stem = _stem(name);
      final syns = _kinship[stem];
      debugPrint('JARVIS contacts: ${contacts.length} kişi, hedef="$name" kök="$stem"');
      // 1) ÖNCE TAM kelime eşleşmesi: stem + akrabalık eş anlamlıları birlikte.
      //    Böylece "anne" → kayıtlı "Valide" ile eşleşir; "Anneanne"yi YANLIŞLIKLA seçmez
      //    (eskiden ek-toleranslı eşleşme "anne"yi "anneanne"ye bağlıyordu — bug buydu).
      final exactTerms = <String>{stem, if (syns != null) ...syns}.toList();
      final exact = _matchContacts(contacts, exactTerms, strict: true);
      if (exact != null) return exact;
      // 2) Tam eşleşme yoksa ek-toleranslı (startsWith) — çekimli/kısmi adlar için ("Sevdem"e).
      final loose = _matchContacts(contacts, [stem], strict: false);
      if (loose != null) return loose;
      debugPrint('JARVIS contacts: eşleşme YOK');
    } catch (e) {
      debugPrint('JARVIS contacts hata: $e');
    }
    return null;
  }

  /// Türkçe -i halini kabaca at: valideyi→valide, annemi→annem, babamı→babam.
  String _stem(String s) {
    s = s.toLowerCase().trim();
    for (final suf in ['yi', 'yı', 'yu', 'yü', 'i', 'ı', 'u', 'ü']) {
      if (s.length > 3 && s.endsWith(suf)) return s.substring(0, s.length - suf.length);
    }
    return s;
  }

  /// Kişi adının KELİMELERİNDE terim eşleşmesi. strict=false → ek toleransı (startsWith).
  String? _matchContacts(List<Contact> contacts, List<String> terms, {required bool strict}) {
    for (final c in contacts) {
      if (c.phones.isEmpty) continue;
      final words = (c.displayName ?? '').toLowerCase().split(RegExp(r'\s+'));
      for (final t in terms) {
        if (t.length < 3) continue;
        for (final w in words) {
          if (w == t || (!strict && w.length >= 3 && (w.startsWith(t) || t.startsWith(w)))) {
            debugPrint('JARVIS contacts: eşleşti "${c.displayName}" (terim=$t)');
            return c.phones.first.number;
          }
        }
      }
    }
    return null;
  }

  Future<String?> _alarm(Map<String, dynamic> args) async {
    final hour = _toInt(args['hour'], 8);
    final minute = _toInt(args['minute'], 0);
    final label = (args['label'] ?? 'Alarm').toString();
    final intent = AndroidIntent(
      action: 'android.intent.action.SET_ALARM',
      arguments: <String, dynamic>{
        'android.intent.extra.alarm.HOUR': hour,
        'android.intent.extra.alarm.MINUTES': minute,
        'android.intent.extra.alarm.MESSAGE': label,
        'android.intent.extra.alarm.SKIP_UI': false,
      },
    );
    await intent.launch();
    return null;
  }

  Future<String?> _openApp(Map<String, dynamic> args) async {
    final name = (args['app_name'] ?? '').toString().toLowerCase();
    const pkgs = {
      'spotify': 'com.spotify.music',
      'whatsapp': 'com.whatsapp',
      'youtube': 'com.google.android.youtube',
      'instagram': 'com.instagram.android',
      'telegram': 'org.telegram.messenger',
      'chrome': 'com.android.chrome',
      'gmail': 'com.google.android.gm',
      'harita': 'com.google.android.apps.maps',
      'maps': 'com.google.android.apps.maps',
    };
    String? pkg;
    for (final e in pkgs.entries) {
      if (name.contains(e.key)) {
        pkg = e.value;
        break;
      }
    }
    if (pkg == null) return '$name için uygulama bulunamadı';
    final intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      package: pkg,
      category: 'android.intent.category.LAUNCHER',
    );
    await intent.launch();
    return null;
  }

  int _toInt(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse('$v') ?? fallback;
  }
}
