import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Thin wrapper around the native `com.ys.locket/wifi` method channel
/// for connecting/disconnecting the phone to/from the Omi device's SoftAP.
///
/// On iOS this uses NEHotspotConfigurationManager.
/// No-op on non-iOS platforms (returns false).
class IOSWifiHelper {
  static const _channel = MethodChannel('com.ys.locket/wifi');

  /// Connect the phone to a WiFi AP with the given SSID and password.
  /// Returns true on success. On iOS, this triggers the system join
  /// prompt (NEHotspotConfiguration).
  static Future<bool> connectToAp(String ssid, String password) async {
    if (!Platform.isIOS) return false;
    try {
      final result = await _channel.invokeMethod<bool>('connectToAp', {
        'ssid': ssid,
        'password': password,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      // User cancelled or network error.
      throw StateError('WiFi AP connection failed: ${e.message}');
    }
  }

  /// Disconnect the phone from a previously joined AP by SSID.
  /// Returns true on success.
  static Future<bool> disconnectFromAp(String ssid) async {
    if (!Platform.isIOS) return false;
    try {
      final result = await _channel.invokeMethod<bool>('disconnectFromAp', {
        'ssid': ssid,
      });
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
