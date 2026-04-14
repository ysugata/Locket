# Omi CV1 → 自前Whisperサーバー 軽量アプリ 実装計画

> このドキュメントは実装計画の **歴史ドキュメント** です。
> 実装途中で計画からズレた場合は、このファイルではなく `README.md` と
> `CLAUDE.md` を更新してください。

## このプロジェクトの目的

Omi CV1 BLEウェアラブルデバイスから音声を取得し、ユーザーが既に運用中のPython製
Whisperサーバー (`wss://whisper.localai.loan`) へ **OPUS生バイトのまま** 転送する、
軽量なFlutterアプリを開発する。Omi社のバックエンド・公式アプリは一切経由しない。

本アプリの責務は **BLE → サーバー転送のみ**。OPUSデコード・文字起こし・保管・閲覧
はすべてサーバー側で完結する。アプリ側でOPUS→PCM変換は行わない。

**プラットフォーム方針**: iOS優先で開発・実機検証する。ただし Flutter の共通コード
で Android もビルドできる状態を維持する (`flutter build apk` がエラーなく通ること)。
Android の動作検証は将来必要になった時点で別タスクとする。

## 確定した前提条件

| 項目 | 確定値 |
|---|---|
| デバイス | Omi CV1 (nRF5340、OPUS 16kHz mono) |
| プラットフォーム | iOS優先 (iOS 15.0+) / Androidもビルド可能 (minSdk 26, Android 8.0+) |
| 開発環境 | macOS + Xcode (iOS) / Android Studio (Android) |
| 動作検証 | iOS実機で実施。Androidは `flutter build apk` が通ることのみ保証 |
| Apple Developer | 契約あり (TestFlight可) |
| Whisperサーバー | Python実装、既存運用中 (`omi_whisper_bridge.py`) |
| サーバー音声受信方式 | OPUS生バイト (サーバー側でデコード) |
| WebSocket URL | `wss://whisper.localai.loan/?token=<AUTH_TOKEN>&codec=opus` |
| 認証 | `?token=<AUTH_TOKEN>` クエリパラメータのみ (Bearerヘッダ非対応) |
| SDアップロードURL | `https://whisper.localai.loan/sdcard/upload` (サーバー側で別途実装予定) |

## アーキテクチャ

```
[Omi CV1 デバイス]
   ↓ BLE GATT (OPUS 16kHz mono、3バイトヘッダ付き)
[本Flutterアプリ] ← ただ流すだけ、デコードしない
   ├─ リアルタイム経路: WebSocket (OPUS生バイト)
   │                     → wss://whisper.localai.loan/?token=...&codec=opus
   └─ SDカード経路: HTTPS POST (OPUS長さプレフィックス形式)
                     → https://whisper.localai.loan/sdcard/upload
                            ↓
                 [既存Whisperサーバー (Python)]
                   - OPUSデコード (新規対応)
                   - 3バイトヘッダ剥がし + フラグメント再構築
                   - faster-whisper 文字起こし
                   - SQLite + JSON 保存
                            ↓
                     [既存Web UI]
```

---

## Omi CV1 の確定仕様

### ハードウェア

- **SoC**: nRF5340 (Nordic Semiconductor、デュアルコア)
- **マイク**: デュアルマイク (PDM)
- **WiFi 6 対応** (高速SD同期に活用可能)
- **ファームウェア**: Zephyr RTOS

### BLE GATT 仕様

```
=== Audio Service ===
Service UUID:           19B10000-E8F2-537E-4F6C-D104768A1214
  Audio Data Char:      19B10001-E8F2-537E-4F6C-D104768A1214 (notify)
  Codec Type Char:      19B10002-E8F2-537E-4F6C-D104768A1214 (read)

=== Storage Service ===
Service UUID:           30295780-4301-EABD-2904-2849ADFEAE43
  Storage Data:         30295781-... (notify)
  Storage Read Control: 30295782-... (write)

=== WiFi Sync Service (CV1専用) ===
  TCP Port: 12345 (SoftAP モード時)

=== Standard Services ===
Battery Service:        0x180F
  Battery Level:        0x2A19 (read/notify)
Device Information:     0x180A
  Firmware Revision:    0x2A26 (read)

=== Features Service ===
Features Service:       19B10020-...
  → CV1 は offlineStorage (1<<6) と wifi (1<<9) ビットが立つ
```

### Audio パケットフォーマット (CV1)

```
[2バイト little-endian: パケット番号 (0-65535)]
[1バイト: フラグメントインデックス]
[音声ペイロード (OPUSエンコード後、約80バイト)]
```

- 1パケット = 10ms分の音声 (16kHz × 0.01s)
- BLE通知頻度: 約100回/秒
- BLE MTU超過時はフラグメント分割される
- **3バイトヘッダはそのままサーバーに送る** (サーバー側で解釈する)

### コーデックID

```
0:  PCM 16bit, 16kHz, mono
1:  PCM 16bit, 8kHz, mono
10: μ-law, 16kHz, 8bit, mono
20: OPUS, 16kHz, mono   ← CV1 のデフォルト
```

CV1 は基本 OPUS (codec=20) で送信。アプリは接続時に Codec Type Char を読み取り、
値が 20 であることを確認して WebSocket クエリに `codec=opus` を付与する。

### SDカード保存形式

OPUSフレームを **長さプレフィックス付き** で保存:

```
[4バイト little-endian: フレーム長][フレームデータ]...
```

参考: BasedHardware/omi の `app/lib/services/wals/sdcard_wal_sync.dart` 内
`_flushToDisk()` メソッド。

---

## Phase 1: プロジェクト初期化

- プロジェクト名: `locket`
- 組織: `com.{userdomain}.locket`
- プラットフォーム: iOS + Android (両方有効)
- Flutter SDK: 3.24+
- 最小iOS: 15.0
- 最小Android: API 26 (Android 8.0)

`flutter create --platforms=ios,android` で作成。web/macos/linux/windows は削除。

### pubspec.yaml

```yaml
name: locket
description: Minimal Omi CV1 → Self-hosted Whisper relay
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: ">=3.24.0"

dependencies:
  flutter:
    sdk: flutter

  # BLE
  omi_sdk: ^1.0.2
  flutter_blue_plus: ^1.32.0

  # 通信
  web_socket_channel: ^2.4.0
  http: ^1.1.0

  # バックグラウンド
  flutter_foreground_task: ^6.1.0

  # ストレージ・権限
  path_provider: ^2.1.0
  shared_preferences: ^2.2.0
  permission_handler: ^11.0.0

  # ファームウェア (CV1の実装方式は要検証、両方入れて切り替え)
  nordic_dfu: ^7.0.0
  # mcumgr_flutter: ^0.4.0  # CV1がSMP方式ならこちら

  cupertino_icons: ^1.0.6

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
```

**重要**:
- OPUSデコーダパッケージ (`opus_dart`, `flutter_opus` 等) は入れない。
  アプリはOPUSをデコードしない
- `omi_sdk` が Android 非対応の場合は `flutter_blue_plus` で両OS共通実装に
  フォールバックする
- `nordic_dfu` / `mcumgr_flutter` は Android でもビルドが通るパッケージを選定する

### ios/Runner/Info.plist 追加項目

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Omi CV1デバイスとの通信に使用します</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Omi CV1デバイスとの通信に使用します</string>
<key>NSMicrophoneUsageDescription</key>
<string>音声録音処理のため</string>
<key>NSLocalNetworkUsageDescription</key>
<string>WiFi同期時のローカル通信に使用します</string>
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>bluetooth-peripheral</string>
  <string>audio</string>
  <string>fetch</string>
  <string>processing</string>
</array>
<key>UIRequiredDeviceCapabilities</key>
<array>
  <string>bluetooth-le</string>
</array>
```

### android/app/src/main/AndroidManifest.xml

```xml
<manifest>
  <!-- BLE -->
  <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
                   android:usesPermissionFlags="neverForLocation" />
  <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
  <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
  <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
  <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />

  <!-- ネットワーク -->
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
  <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
  <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />

  <!-- バックグラウンド録音 (Foreground Service) -->
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
  <uses-permission android:name="android.permission.WAKE_LOCK" />
  <uses-permission android:name="android.permission.RECORD_AUDIO" />

  <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />

  <application android:label="locket" ...>
    <!-- flutter_foreground_task の Service 宣言 -->
    <service
        android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
        android:foregroundServiceType="microphone|connectedDevice"
        android:exported="false" />
  </application>
</manifest>
```

### android/app/build.gradle

```gradle
android {
    compileSdk 34
    defaultConfig {
        minSdk 26
        targetSdk 34
    }
}
```

---

## Phase 2: BLE接続層

`lib/services/omi_device_service.dart`:

```dart
class OmiDeviceService extends ChangeNotifier {
  Future<List<DiscoveredDevice>> scanForDevices({Duration timeout});
  Future<void> connect(String deviceId);
  Future<void> disconnect();

  /// BLE Notify で受信した生バイト (3バイトヘッダ + OPUSペイロード)
  /// デコードや再構築は行わず、そのまま流す
  Stream<Uint8List> get audioStream;

  /// 接続時に Codec Type Char (19B10002-...) から読み取る
  ValueNotifier<int> codecId;  // CV1 は 20 (OPUS)

  ValueNotifier<int> batteryLevel;
  ValueNotifier<ConnectionState> connectionState;
  ValueNotifier<String> firmwareVersion;

  void enableAutoReconnect(bool enabled);  // 15秒間隔リトライ、最大10回
  Future<bool> hasFeature(OmiFeature feature);
}
```

**実装方針**:
- まず `omi_sdk` で実装を試す
- `omi_sdk` が SDカード制御、CV1 の WiFi 同期、または Android に対応していない場合、
  `flutter_blue_plus` で直接実装する (両OS共通コード)
- `audioStream` で受け取るバイトには3バイトヘッダが含まれる。アプリ側で剥がさない
- コーデックIDが 20 (OPUS) 以外だった場合は UI にエラー表示 (本アプリはOPUSのみ対応)
- プラットフォーム分岐 (`Platform.isIOS` / `Platform.isAndroid`) はBLE層内には作らない。
  BLE層は共通コードで書く

---

## Phase 3: WebSocket リアルタイムストリーミング

**サーバー側仕様（既存実装の確認結果）**:

- サーバーファイル: `omi_whisper_bridge.py`
- ルーティング: `websockets.serve(handle_connection, HOST, PORT)` — パス指定なし、
  ルートパス `/` で接続
- 認証: `?token=<AUTH_TOKEN>` クエリパラメータのみ。Bearerヘッダは読まない
- 受信形式: 現状はPCM 16bit/16kHz。**別タスクでOPUS受信対応を追加予定**
- Keep-alive: 2バイト以下のバイナリメッセージは無視される (ping扱い)
- レスポンス: `{"segments": [{"text": "...", "start": 0.0, "end": 1.2, ...}]}` のJSON
- テキストメッセージ (JSON文字列) は `{"type": "..."}` 形式でログされるがコマンド処理はない

`lib/services/whisper_streamer.dart`:

```dart
class WhisperStreamer extends ChangeNotifier {
  final String baseUrl;    // "wss://whisper.localai.loan"
  final String authToken;  // 必須

  WebSocketChannel? _channel;

  Future<void> connect() async {
    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'token': authToken,              // ← 認証はこれのみ
      'codec': 'opus',
      'sample_rate': '16000',
      'channels': '1',
      'language': 'ja',
      'device_id': await _getDeviceId(),
      'frame_header': '3byte',         // Omiの3バイトヘッダ付きであることを明示
    });
    _channel = WebSocketChannel.connect(uri);
    _channel!.stream.listen(_onMessage, onDone: _reconnect);
    _startHeartbeat();
  }

  /// BLE から流れてきたバイトをそのまま送信 (デコードしない)
  void streamAudio(Stream<Uint8List> audioStream) {
    audioStream.listen((bytes) {
      if (_channel?.closeCode == null) {
        _channel?.sink.add(bytes);
      } else {
        _walBuffer.add(bytes);  // オフラインバッファ
      }
    });
  }

  // 30秒ごとに 2バイト ping (サーバーは <=2バイトを無視)
  Timer? _heartbeat;
  void _startHeartbeat() {
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      _channel?.sink.add(Uint8List.fromList([0xFF, 0xFF]));
    });
  }

  // 自動再接続 (5秒間隔、指数バックオフ最大60秒)
  Future<void> _reconnect() async { ... }

  Stream<TranscriptSegment> get transcripts;
}

class TranscriptSegment {
  final double start;
  final double end;
  final String text;
  // サーバーの _offset_segments() が付ける追加フィールドは optional で受ける
}
```

**接続URL例**:
```
wss://whisper.localai.loan/?token=xxxxx&codec=opus&sample_rate=16000&channels=1&language=ja&device_id=abc&frame_header=3byte
```

**注意**: サーバー側のOPUS受信対応が完了するまで、リアルタイム経路は疎通テストしか
できない。完了通知を受けてからPhase 3の結合テストを実施する。

---

## Phase 4: バックグラウンド継続録音

`lib/services/background_service.dart`:

```dart
class BackgroundService {
  Future<void> initialize() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'locket_recording',
        channelName: 'Omi 録音',
        channelDescription: 'BLEデバイスからの音声ストリーミング中',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        autoRunOnBoot: false,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> start() async {
    // iOS: AVAudioSession を PlayAndRecord でアクティベート
    //      → iOS が「audio」バックグラウンドモードを許可
    // Android: Foreground Service 起動で継続動作
    await FlutterForegroundTask.startService(
      notificationTitle: "Omi 録音中",
      notificationText: "BLEデバイスから音声をストリーミングしています",
      callback: backgroundTaskCallback,
    );
  }
}
```

**iOS固有の注意**:
- iOS 17+ は BGTaskScheduler 制約が厳しい
- audio session を維持し続けるアプローチで持続性を上げる
- 完全な常時動作は iOS では困難、ユーザーに認識してもらう

**Android固有の注意**:
- Android 13+ は POST_NOTIFICATIONS をランタイムで要求
- Android 14+ は `foregroundServiceType` 必須 (manifest に `microphone|connectedDevice` を指定済み)
- Doze モード対策として WAKE_LOCK を使用

---

## Phase 5: SDカード同期

**前提**: サーバー側に `/sdcard/upload` エンドポイントが別途実装される。
エンドポイント未完成のうちはPhase 5に着手しない。

`lib/services/sdcard_sync_service.dart`:

BasedHardware/omi の `app/lib/services/wals/sdcard_wal_sync.dart` を簡略化して移植:

```dart
class SDCardSyncService {
  final String uploadUrl;   // "https://whisper.localai.loan/sdcard/upload"
  final String authToken;

  Future<void> syncAll() async {
    // 1. SDカード上のファイル一覧取得
    final storageList = await _getStorageList();
    final totalBytes = storageList[0];
    final offset = storageList.length >= 2 ? storageList[1] : 0;

    if (totalBytes - offset < threshold) return;

    // 2. BLE経由でOPUSフレームを連続受信
    final frames = <List<int>>[];
    final completer = Completer<void>();

    _storageStream.listen((value) {
      // value.length == 83 → 80バイト音声フレーム (3バイトヘッダ付き)
      // value.length == 440 → 複数フレームバッチ
      // value.length == 1   → コマンド応答 (0x00=OK, 0x64=END)
      _parseStorageFrame(value, frames);
      if (_isEnd(value)) completer.complete();
    });

    // 3. read コマンド送信
    await _writeStorageControl(fileNum: 1, command: 0x00, offset: offset);

    // 4. END マーカー受信まで待機
    await completer.future;

    // 5. フレームを長さプレフィックス付きバイナリに変換
    //    (Omi公式と同じ形式: [4バイトLE長][frame]...)
    final body = _encodeLengthPrefixed(frames);

    // 6. HTTP送信 (認証はクエリパラメータで統一)
    final uri = Uri.parse(uploadUrl).replace(queryParameters: {
      'token': authToken,
    });
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Device-Id': deviceId,
        'X-Codec': 'opus',
        'X-Sample-Rate': '16000',
        'X-Channels': '1',
        'X-Timestamp-Start': timestampStart.toString(),
        'X-Frame-Format': 'length-prefixed',
        'X-Frame-Header': '3byte',   // 各フレームに3バイトヘッダが付いている
      },
      body: body,
    );

    // 7. 成功時のみ SD クリア
    if (response.statusCode == 200) {
      await _writeStorageControl(fileNum: 1, command: 0x01, offset: 0);
    }
  }

  ValueNotifier<double> progress = ValueNotifier(0.0);
  ValueNotifier<double> speedKBps = ValueNotifier(0.0);
}
```

認証方式は WebSocket と揃える (既存サーバーは `?token=` クエリなので、新規
`/sdcard/upload` も同じ方式にする合意)。

### CV1向けオプション: WiFi同期 (高速)

CV1 は WiFi 6 対応なので、SoftAP モードで TCP 直接同期も可能:

```dart
Future<void> syncWithWifi() async {
  await _setupWifiSync(ssid, password);  // BLE経由でAP設定
  await _startWifiSync();                // BLE経由でAP起動
  // iOS/Android が SSID に接続
  // TCP ポート12345 に接続して受信 (BLEより10倍以上高速)
  // データ転送後 HTTP送信は同じ
}
```

---

## Phase 6: ファームウェアアップデート

CV1のファームウェア更新方式を要実機検証:

| 方式 | パッケージ | 判定方法 |
|---|---|---|
| Nordic Secure DFU (旧) | `nordic_dfu` | DFU service `00001530-...` の有無 |
| MCUmgr / SMP (Zephyr新) | `mcumgr_flutter` | SMP service `8D53DC1D-...` の有無 |

CV1 は nRF5340 + Zephyr/NCS なのでおそらくMCUmgr方式。両方インストールして実装時に
切り替え。選定したパッケージは iOS/Android 両対応であることを確認する。

`lib/services/firmware_service.dart`:

```dart
class FirmwareService {
  Future<FirmwareInfo?> checkLatest() async {
    final response = await http.get(Uri.parse(
      'https://api.github.com/repos/BasedHardware/omi/releases'
    ));
    final releases = jsonDecode(response.body) as List;

    final cv1Releases = releases.where((r) =>
      (r['tag_name'] as String).startsWith('Omi_CV1_')
    ).toList();

    if (cv1Releases.isEmpty) return null;
    final latest = cv1Releases.first;

    final assets = latest['assets'] as List;
    final firmwareAsset = assets.firstWhere(
      (a) => (a['name'] as String).contains('OTA') &&
             (a['name'] as String).endsWith('.zip'),
      orElse: () => null,
    );

    return FirmwareInfo(
      version: latest['tag_name'],
      downloadUrl: firmwareAsset['browser_download_url'],
      releaseNotes: latest['body'],
    );
  }

  Future<void> performUpdate(FirmwareInfo info) async {
    final localPath = await _downloadFile(info.downloadUrl);
    await NordicDfu().startDfu(deviceId, localPath);
    // または McumgrFirmwareUpdater.update(deviceId, localPath);
  }
}
```

---

## Phase 7: UI

3画面構成:

### `lib/pages/home_page.dart`

- 接続状態 (大きく表示)
- バッテリー残量
- 録音時間
- SD同期進捗 (同期中のみ)
- 直近の文字起こし結果プレビュー (最後の3行)
- 設定アイコン (右上)

### `lib/pages/settings_page.dart`

- **サーバー接続**
  - サーバーベースURL (`https://whisper.localai.loan`)
  - 認証トークン (`AUTH_TOKEN` 1つで WS/HTTP 両方を認証)
- **デバイス**
  - ペアリング済みデバイス選択
  - 「新しいデバイスをスキャン」
- **録音設定**
  - 自動再接続 ON/OFF
  - 言語 (ja / en)
- **ファームウェア**
  - 現在のバージョン
  - 「アップデートを確認」
- **その他**
  - アプリバージョン
  - WALキャッシュサイズ
  - キャッシュクリア

Settings は `baseUrl` + `authToken` の2項目のみ。WebSocket URL と SD アップロード URL
は `baseUrl` から組み立てる (`wss://...` と `https://.../sdcard/upload`)。

### `lib/pages/device_selection_page.dart`

- スキャン中インジケータ
- 発見されたデバイス一覧 (RSSI付き)
- タップでペアリング

**UI方針**:
- Material 3 (iOS/Android 共通ルック)
- ダークモード対応必須
- 日本語ローカライズ
- 派手な装飾なし、機能優先
- アイコンは `cupertino_icons` のみ (`font_awesome`等は入れない)
- プラットフォーム分岐は起動時の権限要求フローのみに限定

---

## Phase 8: ビルド・配布

```bash
# iOS (優先、実機検証)
flutter run --release   # iPhone実機

flutter build ios --release \
  --obfuscate \
  --split-debug-info=./debug-info/ios

# Android (ビルドが通ることのみ確認、配布しない)
flutter build apk --release \
  --obfuscate \
  --split-debug-info=./debug-info/android

flutter build appbundle --release \
  --obfuscate \
  --split-debug-info=./debug-info/android

# サイズ計測 (iOS)
flutter build ios --release --analyze-size
```

**目標サイズ (iOS)**: IPA 30MB以下、App Thinning後 20MB以下
**Android**: `flutter build apk` がエラーなく完了すれば OK。動作検証は将来必要に
なった時点で別タスク

### TestFlight配布手順 (iOS)

1. Xcode で Archive
2. App Store Connect で新規アプリ登録 (公開はしない)
3. TestFlight 内部テスターに自分を追加
4. ビルドアップロード
5. iPhone の TestFlight アプリからインストール
6. ビルドは90日有効、定期再アップロード

---

## やらないこと

- ❌ OPUSデコード (サーバー側で処理)
- ❌ 3バイトヘッダの剥がし・フラグメント再構築 (サーバー側で処理)
- ❌ AIチャット / 会話一覧 / 要約 / App Marketplace / Persona / Brain Map
- ❌ Apple Watch / MCP / Mixpanel / Bugsnag / Sentry / Stripe / Firebase / Google Maps
- ❌ 多言語UI (日本語+英語のみ)
- ❌ オンボーディングチュートリアル
- ❌ Android の実機動作検証 (ビルドが通ることのみ)

---

## ディレクトリ構造

```
locket/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── theme/
│   │   └── app_theme.dart
│   ├── services/
│   │   ├── omi_device_service.dart
│   │   ├── whisper_streamer.dart
│   │   ├── sdcard_sync_service.dart
│   │   ├── wifi_sync_service.dart
│   │   ├── firmware_service.dart
│   │   ├── background_service.dart
│   │   ├── settings_service.dart
│   │   └── wal_buffer_service.dart
│   ├── pages/
│   │   ├── home_page.dart
│   │   ├── settings_page.dart
│   │   ├── device_selection_page.dart
│   │   └── firmware_update_page.dart
│   ├── widgets/
│   │   ├── connection_indicator.dart
│   │   ├── battery_indicator.dart
│   │   ├── transcript_preview.dart
│   │   └── sync_progress_card.dart
│   └── models/
│       ├── transcript_segment.dart
│       ├── device_info.dart
│       └── settings.dart
├── ios/
│   └── Runner/
│       └── Info.plist
├── android/
│   └── app/
│       ├── build.gradle
│       └── src/main/AndroidManifest.xml
├── pubspec.yaml
├── README.md
└── CLAUDE.md
```

---

## 開発スケジュール

| Phase | 内容 | 期間 |
|---|---|---|
| 1 | プロジェクト初期化 (iOS + Android両設定) | 半日 |
| 2 | BLE接続MVP (OPUS生バイト取得) | 1日 |
| 3 | WebSocket実装、疎通テスト (サーバーOPUS対応待ち) | 1日 |
| 4 | バックグラウンド対応・iOS実機検証 | 1日 |
| 5 | SDカード同期実装 (サーバー `/sdcard/upload` 完成後) | 2日 |
| 6 | (オプション) WiFi同期実装 | 1日 |
| 7 | ファームウェアアップデート検証・実装 | 1日 |
| 8 | UI整形 + Androidビルド確認 | 1日 |
| 9 | サイズ最適化、TestFlight配布 | 半日 |
| **合計** | | **約8-9日** |

**サーバー側改修の依存**:
- Phase 3の結合テスト: OPUS受信対応が必要
- Phase 5の着手: `/sdcard/upload` エンドポイントが必要

---

## デバッグ時の注意点

### iOS シミュレータでBLEは動かない

必ず実機 (iPhone) で検証。

### CV1 の MTU

CV1 は BLE 5.x、MTU 247 程度に自動ネゴシエート。

### OPUSを触らないことの検証

アプリ側には `opus_dart` 等のデコーダパッケージを入れていないことを確認。もし疎通で
「文字起こしが空」になっても、デコードはサーバー側の責務なのでアプリ側で調査しない。

### バックグラウンド動作の検証 (iOS)

1. アプリ起動、デバイス接続
2. 文字起こしがWeb UIに流れるのを確認
3. 画面ロック → 30分放置
4. Web UIで継続確認
5. アプリに戻ってログ確認

iOS 17+ ではメモリプレッシャーで kill される可能性大。`flutter_foreground_task` の
通知で持続性向上。

### Android でのBLE権限

Android 12+ は `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` がランタイム権限。
`permission_handler` で起動時に要求すること。Android 11以下は
`ACCESS_FINE_LOCATION` が必要なので `maxSdkVersion="30"` のガードを忘れずに。

### プラットフォーム分岐の最小化

`Platform.isIOS` / `Platform.isAndroid` 分岐は起動時の権限要求フローとバックグラウンド
サービス初期化のみに留める。BLE層・WebSocket層・SD同期層・UI層は共通コードで書く。

### Androidビルド確認

各Phase完了時に `flutter build apk --debug` を実行してコンパイルエラーがないことを
確認。実機動作は検証しないが、コンパイルが通らない状態でiOS実装を進めてはいけない
(後で直すのが高コスト)。

### Whisperサーバー疎通確認

本実装前に wscat/curl で疎通テスト:

```bash
# WebSocket (認証はクエリのみ、パスは / )
wscat -c "wss://whisper.localai.loan/?token=$TOKEN&codec=opus&sample_rate=16000"

# SDアップロード (サーバー側実装後)
curl -X POST "https://whisper.localai.loan/sdcard/upload?token=$TOKEN" \
  -H "Content-Type: application/octet-stream" \
  -H "X-Device-Id: test" \
  -H "X-Codec: opus" \
  -H "X-Sample-Rate: 16000" \
  -H "X-Channels: 1" \
  -H "X-Timestamp-Start: $(date +%s)" \
  -H "X-Frame-Format: length-prefixed" \
  -H "X-Frame-Header: 3byte" \
  --data-binary @test_audio.opus
```

### CV1 ファームウェア方式の判定

nRF Connect for Mobile で CV1 のサービス一覧を確認:
- SMP service `8D53DC1D-1DB7-4CD3-868B-8A527460AA84` あり → MCUmgr 方式
- DFU service `00001530-...` あり → Nordic DFU 方式
