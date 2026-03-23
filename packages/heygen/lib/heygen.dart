/// HeyGen / LiveAvatar integration for this app. Import from the host app.
library;

export 'src/api/live_avatar_client.dart';
export 'src/api/live_avatar_models.dart';
export 'src/presentation/lite_ws_speak.dart'
    show
        liveAvatarLiteSpeakFromText,
        sendLiteSpeakTextViaWebSocket;
export 'src/presentation/live_avatar_session_view.dart'
    show
        LiveAvatarSessionView,
        kLiveAvatarTestSpeakDelay,
        kLiveAvatarTestSpeakPhrase;
