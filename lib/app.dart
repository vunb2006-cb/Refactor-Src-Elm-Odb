import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/connect/connect_screen.dart';
import 'features/connect/debug_screen.dart';
import 'features/home/home_screen.dart';
import 'features/intake/intake_screen.dart';
import 'features/monitor/monitor_screen.dart';
import 'features/session/session_screen.dart';
import 'features/diagnosis/diagnosis_screen.dart';
import 'features/settings/settings_screen.dart';
import 'shared/theme.dart';

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/connect', builder: (_, __) => const ConnectScreen()),
    GoRoute(path: '/debug', builder: (_, __) => const DebugScreen()),
    GoRoute(path: '/intake', builder: (_, __) => const IntakeScreen()),
    GoRoute(path: '/monitor', builder: (_, __) => const LiveMonitorScreen()),
    GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
    GoRoute(path: '/session', builder: (_, __) => const SessionScreen()),
    GoRoute(
      path: '/diagnosis',
      builder: (context, state) {
        final sessionId = state.uri.queryParameters['sessionId'] ?? '';
        return DiagnosisScreen(sessionId: sessionId);
      },
    ),
  ],
);

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ELM OBD2 Diagnostics',
      theme: AppTheme.dark,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
