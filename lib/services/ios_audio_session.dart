import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Thin wrapper around the native `com.ys.locket/audioSession` channel
/// exposed by `ios/Runner/AppDelegate.swift`.
///
/// iOS will only keep the app alive in the background for BLE +
/// relay work if an AVAudioSession is configured and active. Without
/// this, the app is suspended a few minutes after screen lock despite
/// the `bluetooth-central` and `audio` UIBackgroundModes being set.
/// This matches the pattern used by BasedHardware/omi's iOS app.
///
/// No-op on non-iOS platforms so the call sites stay branch-free.
class IOSAudioSession {
  static const _channel = MethodChannel('com.ys.locket/audioSession');

  static Future<bool> configureForBluetooth() async {
    if (!Platform.isIOS) return true;
    try {
      final result = await _channel.invokeMethod<bool>('configureForBluetooth');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> deactivate() async {
    if (!Platform.isIOS) return true;
    try {
      final result = await _channel.invokeMethod<bool>('deactivate');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
