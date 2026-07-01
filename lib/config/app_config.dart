class AppConfig {
  static const String firebaseProjectId = 'crux-8aa85';
  static const String environment = 'production';
  static bool get isProduction => environment == 'production';
  static bool get isDevelopment => environment == 'development';

  // LiveKit server URL (WebSocket) — livekit.cloud hosted
  static const String livekitUrl = 'wss://crux-88fihb12.livekit.cloud';

  // Token server: generates signed LiveKit JWTs from your API key/secret
  // Endpoint: GET /livekit-token?room=<meetingId>&identity=<userId>&name=<userName>
  static const String livekitTokenServerUrl = 'https://crux-new-final.onrender.com';

  /// P2P mesh limit (WebRTC direct — small meetings).
  static const int p2pMaxParticipants = 6;

  /// LiveKit SFU limit (Zoom/Meet-style large webinars).
  static const int livekitMaxParticipants = 1000;

  /// Max video tiles rendered on screen at once (adaptive stream handles the rest).
  static const int livekitVisibleTileCap = 16;
}
