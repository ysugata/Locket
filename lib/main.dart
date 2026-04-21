import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'pages/home_page.dart';
import 'services/background_service.dart';
import 'services/omi_device_service.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // Catch uncaught Flutter framework errors.
  FlutterError.onError = (details) {
    debugPrint('[CRASH] FlutterError: ${details.exception}');
    debugPrint('${details.stack}');
  };

  // Catch uncaught async errors.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    final settings = SettingsService();
    await settings.load();

    final device = OmiDeviceService();
    final background = BackgroundService()..initialize();

    final app = AppController(
      settings: settings,
      device: device,
      background: background,
    );

    runApp(LocketApp(app: app));

    // Defer auto-start to after the first frame so platform channels
    // are ready. Wrapped in try/catch so a failed auto-start doesn't
    // crash the app.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future(() async {
        try {
          await app.tryAutoStart();
        } catch (e, st) {
          debugPrint('[CRASH] tryAutoStart: $e\n$st');
        }
      });
    });
  }, (error, stack) {
    debugPrint('[CRASH] Uncaught: $error\n$stack');
  });
}

class LocketApp extends StatelessWidget {
  final AppController app;
  const LocketApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Locket',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: HomePage(app: app),
      debugShowCheckedModeBanner: false,
    );
  }
}
