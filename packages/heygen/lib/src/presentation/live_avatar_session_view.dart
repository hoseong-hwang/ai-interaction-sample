import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/live_avatar_client.dart';
import '../api/live_avatar_models.dart';
import 'lite_ws_speak.dart';

/// 테스트: 룸 입장 후 [kLiveAvatarTestSpeakDelay] 뒤 [kLiveAvatarTestSpeakPhrase] 를 말하게 함.
///
/// **중요:** `avatar.speak_text`는 [FULL 모드](https://docs.liveavatar.com/docs/full-mode-events)에서만 동작합니다.
/// LITE 모드는 `agent.speak`(PCM Base64) 등 다른 프로토콜을 씁니다.
const Duration kLiveAvatarTestSpeakDelay = Duration(seconds: 5);
const String kLiveAvatarTestSpeakPhrase = '안녕하세요 저는 헤이젠 라이브아바타 입니다';

/// LiveAvatar: session token → start session → [Room.connect] → remote [VideoTrack] 표시.
///
/// 기본 토큰 요청: [CreateSessionTokenRequest.liteSandbox] (샌드박스 LITE).
/// FULL + 웹과 동일 토큰은 [CreateSessionTokenRequest.webLike] 로 넘기세요.
///
/// **LITE 텍스트 말하기:** 서버에 텍스트 API가 없음 → [sendLiteSpeakTextViaWebSocket] 경로
/// (기기 TTS → PCM → `agent.speak`). [showLiteSpeakComposer] 로 입력 UI 제공.
///
/// 웹 SDK의 `session.repeat(text)` 에 대응하는 것은 (FULL) LiveKit `agent-control` 의
/// `avatar.speak_text` 입니다(아래 테스트 지연 전송).
class LiveAvatarSessionView extends StatefulWidget {
  LiveAvatarSessionView({
    super.key,
    required this.apiKey,
    CreateSessionTokenRequest? sessionTokenRequest,
    this.onError,
    this.showLiteSpeakComposer = true,
    this.playDelayedTestPhrase = true,
  }) : sessionTokenRequest =
           sessionTokenRequest ??
           CreateSessionTokenRequest.liteSandbox(
             avatarId: kLiveAvatarSandboxWayneAvatarId,
           );

  final String apiKey;

  /// `POST /v1/sessions/token` 요청 본문 (샌드박스·아바타 등).
  final CreateSessionTokenRequest sessionTokenRequest;

  /// REST 또는 LiveKit 단계 실패 시.
  final void Function(Object error, StackTrace stack)? onError;

  /// `mode == LITE` 이고 WebSocket 이 있을 때, 하단에 **텍스트 → TTS → agent.speak** 입력창 표시.
  final bool showLiteSpeakComposer;

  /// `true` 이면 [kLiveAvatarTestSpeakDelay] 후 자동 테스트 발화 (LITE/FULL 각각 해당 경로).
  final bool playDelayedTestPhrase;

  @override
  State<LiveAvatarSessionView> createState() => _LiveAvatarSessionViewState();
}

class _LiveAvatarSessionViewState extends State<LiveAvatarSessionView> {
  LiveAvatarClient? _apiClient;
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;

  /// LITE: [StartSessionResult.wsUrl] — `agent.speak` 용 WebSocket.
  WebSocketChannel? _liteWs;
  StreamSubscription<dynamic>? _liteWsSubscription;
  Timer? _liteKeepAliveTimer;
  bool _liteConnected = false;

  String? _phase;
  Object? _error;
  VideoTrack? _videoTrack;

  late final TextEditingController _liteSpeakController;
  bool _liteSending = false;

  @override
  void initState() {
    super.initState();
    _liteSpeakController = TextEditingController();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _phase = '세션 생성 중…';
      _error = null;
    });

    final client = LiveAvatarClient(apiKey: widget.apiKey);
    _apiClient = client;

    try {
      final token = await client.createSessionToken(widget.sessionTokenRequest);
      if (!mounted) return;
      setState(() => _phase = '세션 시작 · LiveKit 연결 중…');

      final started = await client.startSession(token.sessionToken);
      if (!mounted) return;

      final sessionId = started.sessionId;
      final tokenMode = widget.sessionTokenRequest.mode;

      final room = Room();
      _room = room;

      final listener = room.createListener()
        ..on<TrackSubscribedEvent>((event) {
          final track = event.track;
          if (track is VideoTrack) {
            if (!mounted) return;
            setState(() => _videoTrack = track);
          }
        })
        ..on<RoomConnectedEvent>((_) {
          final t = _firstRemoteVideoTrack(room);
          if (t != null && mounted) {
            setState(() => _videoTrack = t);
          }
        });
      _roomListener = listener;

      await room.connect(started.livekitUrl, started.livekitClientToken);
      if (!mounted) return;

      setState(() {
        _phase = null;
        _videoTrack ??= _firstRemoteVideoTrack(room);
      });

      if (tokenMode == 'LITE' && started.wsUrl != null) {
        final ws = WebSocketChannel.connect(Uri.parse(started.wsUrl!));
        _liteWs = ws;
        _liteWsSubscription = ws.stream.listen(
          (message) {
            if (message is! String) return;
            try {
              final obj = jsonDecode(message) as Map<String, dynamic>;
              final type = obj['type']?.toString();
              if (type == 'session.state_updated') {
                final state = obj['state']?.toString().toLowerCase();
                if (state == 'connected') {
                  _liteConnected = true;
                }
                debugPrint('LiveAvatar LITE WS state=$state');
              } else if (type == 'agent.speak_started' ||
                  type == 'agent.speak_ended') {
                debugPrint('LiveAvatar LITE WS event=$type');
              }
            } catch (_) {}
          },
          onError: (e, st) {
            debugPrint('LiveAvatar LITE WS listen error: $e\n$st');
          },
          onDone: () {
            _liteConnected = false;
            debugPrint('LiveAvatar LITE WS closed');
          },
        );

        _liteKeepAliveTimer?.cancel();
        _liteKeepAliveTimer = Timer.periodic(const Duration(minutes: 1), (_) {
          try {
            ws.sink.add(
              jsonEncode(<String, dynamic>{
                'type': 'session.keep_alive',
                'event_id': 'flutter-keepalive-${DateTime.now().millisecondsSinceEpoch}',
              }),
            );
          } catch (_) {}
        });
      }

      unawaited(
        _scheduleTestSpeak(
          room,
          sessionId: sessionId,
          mode: tokenMode,
          playTest: widget.playDelayedTestPhrase,
        ),
      );
    } catch (e, st) {
      widget.onError?.call(e, st);
      if (!mounted) return;
      setState(() {
        _phase = null;
        _error = e;
      });
    }
  }

  /// FULL: LiveKit `agent-control` + `avatar.speak_text`.
  /// LITE: [WebSocket](https://docs.liveavatar.com/docs/custom-mode-events) + `agent.speak` (PCM Base64, TTS로 생성).
  Future<void> _scheduleTestSpeak(
    Room room, {
    required String sessionId,
    required String mode,
    required bool playTest,
  }) async {
    if (!playTest) {
      return;
    }
    await Future<void>.delayed(kLiveAvatarTestSpeakDelay);
    if (!mounted) return;

    if (mode == 'LITE') {
      final ws = _liteWs;
      if (ws == null) {
        debugPrint(
          'LiveAvatar LITE: start 응답에 ws_url 이 없어 WebSocket agent.speak 불가. '
          '세션/모드 설정을 확인하세요.',
        );
        return;
      }
      if (!_liteConnected) {
        debugPrint('LiveAvatar LITE: 아직 connected 이벤트 전(전송 시도)');
      }
      try {
        await sendLiteSpeakTextViaWebSocket(
          channel: ws,
          text: kLiveAvatarTestSpeakPhrase,
        );
      } catch (e, st) {
        debugPrint('LiveAvatar LITE agent.speak: $e\n$st');
      }
      return;
    }

    if (mode != 'FULL') {
      debugPrint('LiveAvatar: 알 수 없는 mode=$mode');
      return;
    }

    try {
      await _sendAvatarSpeakText(
        room,
        text: kLiveAvatarTestSpeakPhrase,
        sessionId: sessionId,
      );
      debugPrint('LiveAvatar: avatar.speak_text 전송 완료 (session_id 포함)');
    } catch (e, st) {
      debugPrint('LiveAvatar speak_text (test): $e\n$st');
    }
  }

  static Future<void> _sendAvatarSpeakText(
    Room room, {
    required String text,
    required String sessionId,
  }) async {
    final local = room.localParticipant;
    if (local == null) {
      debugPrint('LiveAvatar speak_text: localParticipant is null');
      return;
    }
    final payload = jsonEncode(<String, String>{
      'event_type': 'avatar.speak_text',
      'session_id': sessionId,
      'text': text,
    });
    await local.publishData(
      utf8.encode(payload),
      reliable: true,
      topic: 'agent-control',
    );
  }

  Future<void> _sendLiteComposerText() async {
    final ws = _liteWs;
    if (ws == null) {
      return;
    }
    final text = _liteSpeakController.text.trim();
    if (text.isEmpty) {
      return;
    }
    if (!_liteConnected) {
      debugPrint('LiveAvatar LITE: 아직 connected 이벤트 전(전송 시도)');
    }
    setState(() => _liteSending = true);
    try {
      await sendLiteSpeakTextViaWebSocket(channel: ws, text: text);
    } catch (e, st) {
      debugPrint('LiveAvatar LITE 입력 말하기: $e\n$st');
    } finally {
      if (mounted) {
        setState(() => _liteSending = false);
      }
    }
  }

  VideoTrack? _firstRemoteVideoTrack(Room room) {
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final track = pub.track;
        if (track is VideoTrack) {
          return track;
        }
      }
    }
    return null;
  }

  @override
  void dispose() {
    final room = _room;
    final listener = _roomListener;
    final client = _apiClient;
    final liteWs = _liteWs;
    final liteWsSub = _liteWsSubscription;
    final keepAliveTimer = _liteKeepAliveTimer;
    _room = null;
    _roomListener = null;
    _apiClient = null;
    _liteWs = null;
    _liteWsSubscription = null;
    _liteKeepAliveTimer = null;
    _liteConnected = false;
    _liteSpeakController.dispose();

    unawaited(
      Future(() async {
        await listener?.dispose();
        await liteWsSub?.cancel();
        keepAliveTimer?.cancel();
        if (room != null) {
          await room.disconnect();
          await room.dispose();
        }
        client?.close();
        await liteWs?.sink.close();
      }),
    );

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('오류: $err', textAlign: TextAlign.center),
        ),
      );
    }

    final track = _videoTrack;
    if (track != null) {
      final showLiteBar = widget.sessionTokenRequest.mode == 'LITE' &&
          widget.showLiteSpeakComposer &&
          _liteWs != null;

      final video = Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: VideoTrackRenderer(track, fit: VideoViewFit.cover),
        ),
      );

      if (!showLiteBar) {
        return video;
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          video,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: Colors.black.withOpacity(0.72),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 12,
                    right: 12,
                    bottom: 12 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _liteSpeakController,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText:
                                'LITE: 텍스트 입력 → 기기 TTS → PCM → agent.speak',
                            hintStyle: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          maxLines: 3,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendLiteComposerText(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _liteSending ? null : _sendLiteComposerText,
                        child: _liteSending
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('말하기'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          if (_phase != null) ...[
            const SizedBox(height: 16),
            Text(_phase!, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}
