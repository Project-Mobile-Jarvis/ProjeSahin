import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config.dart';

/// Backend ile HTTP iletişimi: /stt, /chat, /tts. Tüm anahtarlar backend'de;
/// app sadece X-API-Key (paylaşılan sır) gönderir.
class BackendClient {
  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: Config.backendUrl,
      headers: {'X-API-Key': Config.apiKey},
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 90), // agentic /chat yavaş olabilir
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  /// Ses dosyası → Türkçe metin (Deepgram/Whisper). [keyterms]: boost (isimler+komutlar, virgüllü).
  Future<String> stt(String audioPath, {String? keyterms}) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(audioPath, filename: 'audio.m4a'),
      if (keyterms != null && keyterms.trim().isNotEmpty) 'keyterms': keyterms,
    });
    final resp = await _dio.post('/stt', data: form);
    return (resp.data['text'] ?? '') as String;
  }

  /// Metin → {action, args, reply} (Gemini agentic). Konum varsa "en yakın"/save_location için gönderilir.
  Future<ChatResult> chat(String message, {double? lat, double? lng}) async {
    final body = <String, dynamic>{
      'session_id': Config.sessionId,
      'message': message,
    };
    if (lat != null && lng != null) {
      body['location'] = {'lat': lat, 'lng': lng};
    }
    final resp = await _dio.post('/chat', data: body);
    final data = Map<String, dynamic>.from(resp.data as Map);
    return ChatResult(
      action: (data['action'] ?? 'chat_reply') as String,
      args: Map<String, dynamic>.from((data['args'] ?? {}) as Map),
      reply: (data['reply'] ?? '') as String,
    );
  }

  /// Metin → mp3 sesi (Google Chirp 3 HD).
  Future<Uint8List> tts(String text) async {
    final resp = await _dio.post(
      '/tts',
      data: {'text': text},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data as List<int>);
  }
}

/// /chat cevabı.
class ChatResult {
  final String action;
  final Map<String, dynamic> args;
  final String reply;

  ChatResult({required this.action, required this.args, required this.reply});
}
