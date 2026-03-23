import 'package:flutter/material.dart';
import 'package:heygen/heygen.dart';

/// **LITE 모드** 샌드박스 (Wayne).
///
/// 실행: `flutter run --dart-define=LIVEAVATAR_API_KEY=...`
///
/// **LITE에서 텍스트로 말하기:** 서버가 TTS 하지 않음. 화면 하단 입력 → 기기 `flutter_tts` →
/// PCM → WebSocket `agent.speak` ([sendLiteSpeakTextViaWebSocket]).
/// FULL에서만 LiveKit `avatar.speak_text`(텍스트 직접) — `CreateSessionTokenRequest.webLike`.
class HeygenPage extends StatelessWidget {
  const HeygenPage({super.key});

  static const String _apiKey = 'a26bcca1-1c25-11f1-a99e-066a7fa2e369';

  static final CreateSessionTokenRequest _sessionRequest =
      CreateSessionTokenRequest.liteSandbox(
        avatarId: kLiveAvatarSandboxWayneAvatarId,
        isSandbox: true,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'HeyGen - Live Avatar (LITE)',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
      body: _apiKey.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'LIVEAVATAR_API_KEY 가 없습니다.\n\n'
                  'flutter run --dart-define=LIVEAVATAR_API_KEY=대시보드_API_키',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : LiveAvatarSessionView(
              apiKey: _apiKey,
              sessionTokenRequest: _sessionRequest,
            ),
    );
  }
}
