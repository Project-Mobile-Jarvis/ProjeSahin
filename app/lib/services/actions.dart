import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

/// Backend'den gelen aksiyon JSON'unu telefonda uygular (SPEC Faz 6).
/// Cihaz tool'ları: navigate_to, make_call, set_alarm, open_app.
class DeviceActions {
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
    if (target.isEmpty) return null;
    final number = await _resolveContact(target);
    if (number == null) {
      // Rehberde bulunamadı; hedef zaten numara olabilir (rakam içeriyorsa) onu dene.
      if (RegExp(r'\d{3,}').hasMatch(target)) {
        await launchUrl(Uri(scheme: 'tel', path: target.replaceAll(' ', '')),
            mode: LaunchMode.externalApplication);
        return null;
      }
      return '$target rehberde bulunamadı';
    }
    await launchUrl(Uri(scheme: 'tel', path: number.replaceAll(' ', '')),
        mode: LaunchMode.externalApplication);
    return null;
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
      if (!status.isGranted) return null;
      final contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      final n = name.toLowerCase().trim();
      final terms = <String>{n, ...?_kinship[n]};
      for (final c in contacts) {
        if (c.phones.isEmpty) continue;
        final dn = (c.displayName ?? '').toLowerCase();
        for (final t in terms) {
          if (dn.contains(t)) return c.phones.first.number;
        }
      }
    } catch (_) {}
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
