import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// LiveKit SFU helpers — token fetch + room limits for large conferences (1000+).
class LiveKitService {
  LiveKitService._();
  static final LiveKitService instance = LiveKitService._();

  /// Fetch a signed JWT from the CRUX token server (Render.com).
  Future<String?> fetchToken({
    required String room,
    required String identity,
    required String name,
    bool isHost = false,
  }) async {
    try {
      final uri = Uri.parse(
        '${AppConfig.livekitTokenServerUrl}/livekit-token'
        '?room=${Uri.encodeComponent(room)}'
        '&identity=${Uri.encodeComponent(identity)}'
        '&name=${Uri.encodeComponent(name)}'
        '&host=${isHost ? 'true' : 'false'}',
      );
      final res = await http.get(uri).timeout(
        const Duration(seconds: 25),
        onTimeout: () => http.Response('timeout', 408),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['token'] as String?;
      }
    } catch (_) {}
    return null;
  }
}
