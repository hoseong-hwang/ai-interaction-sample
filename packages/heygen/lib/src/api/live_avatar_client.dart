import 'dart:convert';

import 'package:http/http.dart' as http;

import 'live_avatar_models.dart';

/// Minimal LiveAvatar REST client for **testing from the app** (API key on device).
///
/// **Production:** call these endpoints from your backend; do not ship API keys.
class LiveAvatarClient {
  LiveAvatarClient({
    required String apiKey,
    String baseUrl = 'https://api.liveavatar.com',
    http.Client? httpClient,
  }) : _apiKey = apiKey,
       _baseUrl = baseUrl.replaceAll(RegExp(r'/$'), ''),
       _http = httpClient ?? http.Client();

  final String _apiKey;
  final String _baseUrl;
  final http.Client _http;

  /// `POST /v1/sessions/token` — uses header `X-API-KEY`.
  Future<SessionTokenResult> createSessionToken(
    CreateSessionTokenRequest request,
  ) async {
    final uri = Uri.parse('$_baseUrl/v1/sessions/token');
    final response = await _http.post(
      uri,
      headers: {
        'X-API-KEY': _apiKey,
        'accept': 'application/json',
        'content-type': 'application/json',
      },
      body: jsonEncode(request.toJson()),
    );

    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LiveAvatarApiException(
        message: _liveAvatarHttpErrorMessage(
          'createSessionToken',
          response.statusCode,
          body,
        ),
        statusCode: response.statusCode,
        body: body,
      );
    }

    final json = parseJsonObject(body);
    ensureApiEnvelope(json);
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw LiveAvatarApiException(
        message: 'Missing data in token response',
        body: body,
      );
    }
    final sessionId = data['session_id'] as String?;
    final sessionToken = data['session_token'] as String?;
    if (sessionId == null || sessionToken == null) {
      throw LiveAvatarApiException(
        message: 'Missing session_id or session_token',
        body: body,
      );
    }
    return SessionTokenResult(sessionId: sessionId, sessionToken: sessionToken);
  }

  /// `POST /v1/sessions/start` — uses `Authorization: Bearer <session_token>`.
  ///
  /// Returns [StartSessionResult.livekitUrl] and [StartSessionResult.livekitClientToken]
  /// for `package:livekit_client` `Room.connect`.
  Future<StartSessionResult> startSession(String sessionToken) async {
    final uri = Uri.parse('$_baseUrl/v1/sessions/start');
    final response = await _http.post(
      uri,
      headers: {
        'accept': 'application/json',
        'authorization': 'Bearer $sessionToken',
        'content-type': 'application/json',
      },
    );

    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LiveAvatarApiException(
        message: _liveAvatarHttpErrorMessage(
          'startSession',
          response.statusCode,
          body,
        ),
        statusCode: response.statusCode,
        body: body,
      );
    }

    final json = parseJsonObject(body);
    ensureApiEnvelope(json);
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw LiveAvatarApiException(
        message: 'Missing data in start response',
        body: body,
      );
    }
    final sessionId = data['session_id'] as String?;
    final livekitUrl = data['livekit_url'] as String?;
    final livekitClientToken = data['livekit_client_token'] as String?;
    if (sessionId == null || livekitUrl == null || livekitClientToken == null) {
      throw LiveAvatarApiException(
        message: 'Missing session_id, livekit_url, or livekit_client_token',
        body: body,
      );
    }
    return StartSessionResult(
      sessionId: sessionId,
      livekitUrl: livekitUrl,
      livekitClientToken: livekitClientToken,
      livekitAgentToken: data['livekit_agent_token'] as String?,
      maxSessionDuration: data['max_session_duration'] as int?,
      wsUrl: data['ws_url'] as String?,
    );
  }

  void close() {
    _http.close();
  }
}

/// HTTP 실패 시 응답 JSON 의 `message` 등을 뽑아 디버깅·UI에 쓰기 쉽게 함.
String _liveAvatarHttpErrorMessage(
  String op,
  int statusCode,
  String body,
) {
  final detail = parseLiveAvatarErrorDetail(body);
  if (detail != null && detail.isNotEmpty) {
    return '$op failed ($statusCode): $detail';
  }
  return '$op failed ($statusCode)';
}
