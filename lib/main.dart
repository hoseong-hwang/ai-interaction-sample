import 'package:ai_interaction_sample/app_routes.dart';
import 'package:ai_interaction_sample/heygen_live_avatar_screen.dart';
import 'package:ai_interaction_sample/main_screen.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      initialRoute: AppRoutes.main,
      routes: {
        AppRoutes.main: (context) => const MainScreen(),
        AppRoutes.heygenLiveAvatar: (context) =>
            const HeyGenLiveAvatarScreen(),
      },
    );
  }
}
