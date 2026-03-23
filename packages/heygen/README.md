# heygen

Local Flutter package: HeyGen (Live Avatar, API clients, widgets).

Host app depends on it via `path: packages/heygen` in the root `pubspec.yaml`.

## Layout (grow as needed)

- `lib/heygen.dart` — public exports
- `lib/src/api/` — LiveAvatar HTTP client (`LiveAvatarClient`)
- `lib/src/presentation/` — screens & UI

## LiveAvatar client (local testing)

```dart
final client = LiveAvatarClient(apiKey: yourKey);
final token = await client.createSessionToken(
  CreateSessionTokenRequest(
    avatarId: kLiveAvatarSandboxWayneAvatarId,
    isSandbox: true,
  ),
);
final room = await client.startSession(token.sessionToken);
// room.livekitUrl + room.livekitClientToken → livekit_client Room.connect
```

**Security:** do not ship API keys in production; use a backend for session tokens.

### Session concurrency limit (동시 세션 제한)

- **샌드박스(`is_sandbox: true`)는 아바타/테스트 환경만 바꾸는 것이고, API 키의 “동시에 열 수 있는 세션 수” 같은 **플랜 한도는 그대로**입니다.
- `session concurrency limit` / `429` 류는 **다른 터미널·시뮬레이터·웹 대시보드에서 열린 세션**이 아직 끊기지 않았을 때 자주 납니다.
- **대응:** 다른 기기/탭에서 끄기, 앱에서 뒤로 가기 전에 화면 `dispose`로 LiveKit `disconnect` 되게 두기(이미 `LiveAvatarSessionView`는 `dispose`에서 끊음), **몇 분 대기** 후 재시도, HeyGen 대시보드에서 활성 세션·플랜 확인.

## `LiveAvatarSessionView`

Bundles token → `startSession` → `Room.connect` → `VideoTrackRenderer`. Pass `apiKey` and optional `CreateSessionTokenRequest`.

### LITE + “텍스트로 말하기”

LITE는 서버 텍스트 TTS가 없음. **`sendLiteSpeakTextViaWebSocket`** (또는 **`liveAvatarLiteSpeakFromText`**) 가
`flutter_tts` → PCM 24kHz → WebSocket `agent.speak` 를 수행한다.
`LiveAvatarSessionView` 에 **`showLiteSpeakComposer: true`**(기본)면 하단 입력창이 뜬다.
