import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app alive while BLE audio relay is running.
///
/// On Android this starts a foreground service so the OS won't kill
/// the process while the screen is off. On iOS it posts a persistent
/// notification and — combined with the `audio` UIBackgroundMode and
/// an active AVAudioSession — keeps the app in the background as long
/// as possible. Neither platform guarantees indefinite execution.
///
/// BLE streaming and WebSocket relay keep running in the main isolate
/// alongside the UI: this service only provides the priority boost and
/// the visible notification. No separate TaskHandler is registered,
/// so `ForegroundTaskEventAction.nothing()` is used.
class BackgroundService {
  static const _channelId = 'locket_recording';
  static const _channelName = 'Omi 録音';
  static const _channelDescription = 'BLEデバイスからの音声ストリーミング中';

  bool _initialized = false;

  void initialize() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: _channelName,
        channelDescription: _channelDescription,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
      ),
    );
    _initialized = true;
  }

  Future<bool> start({
    String title = 'Omi 録音中',
    String text = 'BLEデバイスから音声をストリーミングしています',
  }) async {
    if (!_initialized) initialize();
    if (await FlutterForegroundTask.isRunningService) return true;
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [
        ForegroundServiceTypes.microphone,
        ForegroundServiceTypes.connectedDevice,
      ],
      notificationTitle: title,
      notificationText: text,
    );
    return result is ServiceRequestSuccess;
  }

  Future<bool> updateNotification({
    required String title,
    required String text,
  }) async {
    if (!await FlutterForegroundTask.isRunningService) return false;
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
    return result is ServiceRequestSuccess;
  }

  Future<bool> stop() async {
    if (!await FlutterForegroundTask.isRunningService) return true;
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  }

  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}
