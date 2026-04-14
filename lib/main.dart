import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'pages/home_page.dart';
import 'services/background_service.dart';
import 'services/omi_device_service.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
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

  // Fire-and-forget: a configured user shouldn't have to tap "start"
  // every time they launch the app. Errors are surfaced via
  // app.lastError and shown in the home page status card.
  // ignore: unawaited_futures, discarded_futures
  app.tryAutoStart();
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
