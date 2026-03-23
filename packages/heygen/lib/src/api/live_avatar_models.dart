import 'dart:convert';

/// Thrown when the LiveAvatar HTTP API returns an error or unexpected payload.
final class LiveAvatarApiException implements Exception {
  LiveAvatarApiException({required this.message, this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() =>
      'LiveAvatarApiException($statusCode): $message${body != null ? ' — $body' : ''}';
}

/// Response from `POST /v1/sessions/token`.
final class SessionTokenResult {
  const SessionTokenResult({
    required this.sessionId,
    required this.sessionToken,
  });

  final String sessionId;
  final String sessionToken;
}

/// Response from `POST /v1/sessions/start` (LiveKit fields for [Room.connect]).
final class StartSessionResult {
  const StartSessionResult({
    required this.sessionId,
    required this.livekitUrl,
    required this.livekitClientToken,
    this.livekitAgentToken,
    this.maxSessionDuration,
    this.wsUrl,
  });

  final String sessionId;
  final String livekitUrl;
  final String livekitClientToken;
  final String? livekitAgentToken;
  final int? maxSessionDuration;
  final String? wsUrl;
}

/// Request body for creating a session token.
///
/// Sandbox: set [isSandbox] to `true` and use a sandbox-allowed [avatarId]
/// (see LiveAvatar docs — e.g. Wayne in sandbox).
final class CreateSessionTokenRequest {
  const CreateSessionTokenRequest({
    required this.avatarId,
    this.mode = 'LITE',
    this.isSandbox = true,
    this.avatarPersona,
    this.videoSettings,
    this.maxSessionDuration,
    this.interactivityType,
    this.extra,
  });

  final String avatarId;

  /// `FULL` | `LITE` | `CUSTOM` — match LiveAvatar API.
  final String mode;
  final bool isSandbox;
  final Map<String, dynamic>? avatarPersona;
  final Map<String, dynamic>? videoSettings;
  final int? maxSessionDuration;
  final String? interactivityType;

  /// Merged last so you can pass any extra fields from the OpenAPI spec.
  final Map<String, dynamic>? extra;

  /// 웹 프로토타입 `createSessionToken` 과 동일한 형태:
  /// `mode: FULL`, `avatar_persona: { language, context_id? }` — **voice_id 없음**.
  factory CreateSessionTokenRequest.webLike({
    required String avatarId,
    bool isSandbox = true,
    String language = 'ko',
    String? contextId,
  }) {
    final persona = <String, dynamic>{'language': language};
    if (contextId != null && contextId.trim().isNotEmpty) {
      persona['context_id'] = contextId.trim();
    }
    return CreateSessionTokenRequest(
      avatarId: avatarId,
      mode: 'FULL',
      isSandbox: isSandbox,
      avatarPersona: persona,
    );
  }

  /// 샌드박스 테스트용 **LITE** 세션 (`mode: LITE`).
  ///
  /// **텍스트만 보내서 말하기(서버 TTS)** 는 LITE에 없음. LITE는 WebSocket `agent.speak`에
  /// **PCM 16-bit 24kHz**(Base64)만 받음 → 앱에서 `flutter_tts` 등으로 음성 만든 뒤
  /// `sendLiteSpeakTextViaWebSocket` / `liveAvatarLiteSpeakFromText` 사용.
  /// FULL 텍스트는 LiveKit `avatar.speak_text` ([Full mode](https://docs.liveavatar.com/docs/full-mode-events)).
  factory CreateSessionTokenRequest.liteSandbox({
    required String avatarId,
    bool isSandbox = true,
    Map<String, dynamic>? extra,
  }) {
    return CreateSessionTokenRequest(
      avatarId: avatarId,
      mode: 'LITE',
      isSandbox: isSandbox,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'avatar_id': avatarId,
      'mode': mode,
      'is_sandbox': isSandbox,
      if (avatarPersona != null) 'avatar_persona': avatarPersona,
      if (videoSettings != null) 'video_settings': videoSettings,
      if (maxSessionDuration != null)
        'max_session_duration': maxSessionDuration,
      if (interactivityType != null) 'interactivity_type': interactivityType,
    };
    if (extra != null) {
      map.addAll(extra!);
    }
    return map;
  }
}

/// Default sandbox avatar id from LiveAvatar sandbox docs (verify in dashboard).
const String kLiveAvatarSandboxWayneAvatarId =
    'dd73ea75-1218-4ef3-92ce-606d5f7fbc0a';

Map<String, dynamic> parseJsonObject(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw LiveAvatarApiException(message: 'Expected JSON object in response');
  }
  return decoded;
}

/// LiveAvatar API는 문서/환경에 따라 성공 `code`가 [100] 또는 [1000]으로 올 수 있음.
const Set<int> kLiveAvatarSuccessCodes = {100, 1000};

void ensureApiEnvelope(Map<String, dynamic> json) {
  final code = json['code'];
  if (code is int && !kLiveAvatarSuccessCodes.contains(code)) {
    final msg = json['message']?.toString() ?? 'API error';
    throw LiveAvatarApiException(message: msg, body: json.toString());
  }
  // code가 없거나 알 수 없는 타입이면 data 파싱 단계에서 걸러짐
}

/// HTTP 4xx/5xx 본문 JSON에서 `message` 등을 뽑음 (동시 세션 제한 등).
String? parseLiveAvatarErrorDetail(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final m = decoded['message'];
    if (m is String && m.trim().isNotEmpty) {
      return m.trim();
    }
    final d = decoded['data'];
    if (d is Map<String, dynamic>) {
      final dm = d['message'];
      if (dm is String && dm.trim().isNotEmpty) {
        return dm.trim();
      }
    }
    final err = decoded['error'];
    if (err is String && err.trim().isNotEmpty) {
      return err.trim();
    }
  } catch (_) {
    return null;
  }
  return null;
}
