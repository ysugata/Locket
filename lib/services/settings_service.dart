import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const _kBaseUrl = 'baseUrl';
  static const _kAuthToken = 'authToken';
  static const _kLanguage = 'language';
  static const _kDeviceId = 'deviceId';
  static const _kPairedBleId = 'pairedBleId';
  static const _kPairedBleName = 'pairedBleName';
  static const _kAutoReconnect = 'autoReconnect';

  static const defaultBaseUrl = 'https://whisper.localai.loan';
  static const defaultLanguage = 'ja';

  late SharedPreferences _prefs;
  bool _loaded = false;

  String _baseUrl = defaultBaseUrl;
  String _authToken = '';
  String _language = defaultLanguage;
  String _deviceId = '';
  String? _pairedBleId;
  String? _pairedBleName;
  bool _autoReconnect = true;

  bool get isLoaded => _loaded;
  String get baseUrl => _baseUrl;
  String get authToken => _authToken;
  String get language => _language;
  String get deviceId => _deviceId;
  String? get pairedBleId => _pairedBleId;
  String? get pairedBleName => _pairedBleName;
  bool get autoReconnect => _autoReconnect;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _baseUrl = _prefs.getString(_kBaseUrl) ?? defaultBaseUrl;
    _authToken = _prefs.getString(_kAuthToken) ?? '';
    _language = _prefs.getString(_kLanguage) ?? defaultLanguage;
    _pairedBleId = _prefs.getString(_kPairedBleId);
    _pairedBleName = _prefs.getString(_kPairedBleName);
    _autoReconnect = _prefs.getBool(_kAutoReconnect) ?? true;

    var id = _prefs.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = _generateDeviceId();
      await _prefs.setString(_kDeviceId, id);
    }
    _deviceId = id;

    _loaded = true;
    notifyListeners();
  }

  Future<void> setBaseUrl(String value) async {
    _baseUrl = value.trim();
    await _prefs.setString(_kBaseUrl, _baseUrl);
    notifyListeners();
  }

  Future<void> setAuthToken(String value) async {
    _authToken = value.trim();
    await _prefs.setString(_kAuthToken, _authToken);
    notifyListeners();
  }

  Future<void> setLanguage(String value) async {
    _language = value;
    await _prefs.setString(_kLanguage, _language);
    notifyListeners();
  }

  Future<void> setPairedDevice({required String id, required String name}) async {
    _pairedBleId = id;
    _pairedBleName = name;
    await _prefs.setString(_kPairedBleId, id);
    await _prefs.setString(_kPairedBleName, name);
    notifyListeners();
  }

  Future<void> clearPairedDevice() async {
    _pairedBleId = null;
    _pairedBleName = null;
    await _prefs.remove(_kPairedBleId);
    await _prefs.remove(_kPairedBleName);
    notifyListeners();
  }

  Future<void> setAutoReconnect(bool value) async {
    _autoReconnect = value;
    await _prefs.setBool(_kAutoReconnect, value);
    notifyListeners();
  }

  String _generateDeviceId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(12, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
