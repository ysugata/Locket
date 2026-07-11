# Locket

Omi CV1 BLE ウェアラブルから音声を取得し、自前の Whisper サーバー
(`omi_whisper_bridge.py`) へ **OPUS 生バイトのまま** 転送する Flutter アプリ
(iOS 優先 / Android はビルド保証のみ)。

アプリは「BLE → サーバー転送」の薄い中継に徹する。OPUS のデコード、
3 バイトヘッダの除去、フラグメント再構築、無音判定はすべて **サーバー責務**。

## 機能

- **BLE 接続**: Omi CV1 をスキャン → ペアリング → 自動接続。バッテリー残量・
  ファームウェアバージョン表示
  - 切断時は**回数無制限**で自動再接続（3 秒から始まり最大 30 秒間隔の
    バックオフ、成功でリセット）
  - 起動時に接続に失敗しても 30 秒間隔で自動再試行。ホーム画面から
    手動「再接続」も可能
  - 接続中は 3 秒ごとの RSSI 読み取りで supervision timeout 切断を予防
  - デバイスのコーデックが OPUS 以外の場合は警告を表示
- **ライブ中継**: BLE Notify で受けた音声バイト列（3 バイト Omi ヘッダ付き）を
  そのまま WebSocket でブリッジに送信
  - クライアント側の VAD・フレーム間引きは行わない（全フレーム送信、
    無音処理はサーバー責務）。パケット ID ギャップの検知・統計のみ実施
- **オフライン WAL（二段構え）**: WS 切断中の音声はまずメモリに退避し、
  再接続時に WS でフラッシュ。約 15 秒分を超えた分は**ディスクに永続化**し、
  接続回復時・次回起動時に `POST /sdcard/upload` で回収
  - セグメントは `Documents/wal/wal_<開始epoch>_<連番>.bin`
    （`[len:4 LE][frame]...`、アップロード成功後に削除）
  - `X-Timestamp-Start` に録音開始時刻を設定するため、後から回収しても
    文字起こしの時刻は録音時刻になる
  - 合計 500MB 上限（超過時は最古から削除）。アプリの kill・クラッシュでも
    音声が消えない
- **SD カード同期**: CV1 の SD に溜まった録音を BLE 経由で吸い上げ、
  `POST /sdcard/upload` に一括アップロード。接続確立時に自動実行
  - マルチファイル (CMD_LIST 0x10 / CMD_READ 0x11 / CMD_DELETE 0x12) と
    レガシー (0x00 read / 0x01 clear) の両プロトコルを自動判別
  - ファイル一覧の取得は STOP → 500ms 待機 → 応答が無ければ最大 3 回
    リトライ（公式クライアントの "PR #5905 pattern" に準拠）
  - タイムアウトは**無通信ベース**（最初のデータ 5 秒 / 転送中の停止 30 秒）。
    データが流れ続けている限り何時間分でも転送を継続する
  - 転送が停止した場合は **CMD_READ_FILE の offset で続きから再開**
    （進捗がある限り最大 10 回）。大容量ファイルでも最初からやり直しにならない
  - BLE が切断→再接続した場合、SD 同期と WAL 回収を自動で再開
  - **完全受信 (END マーカー + 全バイト) かつアップロード成功したファイルだけ削除**。
    部分読み出しでは絶対に削除しない
  - 削除は全ファイル読了後に**降順 index で実行**（ファーム側の index
    振り直しに対応）
  - 録音時刻はファイルリストのタイムスタンプ → データ内タイムスタンプ →
    同期時刻の優先順で `X-Timestamp-Start` に設定
  - HTTP アップロードは 60 秒タイムアウト + チャンクごとに最大 3 回再試行
- **WiFi 同期**: CV1 の SoftAP + TCP 経由の高速同期（WiFi 対応ファームのみ）
- **ファームウェア更新**: MCUmgr / Nordic DFU
- **バックグラウンド録音**: foreground service + AVAudioSession で
  画面ロック中も中継を継続

## 設定項目

| 項目 | 説明 |
|---|---|
| `baseUrl` | ブリッジのベース URL (既定: `https://whisper.localai.loan`)。WS / アップロード URL はここから組み立て |
| `authToken` | `?token=` クエリで渡す認証トークン |
| 言語 | 文字起こし言語 (既定: `ja`) |
| ペアリングデバイス | スキャン画面で選択した Omi CV1 |
| 自動再接続 | BLE 切断時に自動で再接続するか |

## サーバープロトコル

- WebSocket: `wss://<host>/?token=<TOKEN>&codec=opus&frame_header=3byte`
  へ接続し、BLE Notify のバイト列（3 バイトヘッダ付き）を binary フレームで
  そのまま送る。ハンドシェイクなし。Omi 互換 HTTP ヘッダー必須
  (`CLAUDE.md` 参照)
- SD アップロード: `POST /sdcard/upload?token=<TOKEN>`、body は
  `[len:4 LE][OPUS frame]...` の連結（ヘッダなしフレーム）

## 画面構成

- **ホーム**: BLE / WS 接続状態、バッテリー、文字起こしフィード、
  SD 同期の進捗と最終結果、未送信バッファ量（メモリ / ディスク）、
  パケットギャップ統計、手動再接続ボタン、デバッグログ
- **デバイス選択**: スキャン結果一覧からペアリング
- **設定**: baseUrl / トークン / 言語 / ペアリング解除 / ファーム更新

## 開発

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --debug --no-codesign
flutter build apk --debug
flutter run --release   # iOS 実機 (BLE はシミュレータ不可)
```

主要ソース:

| ファイル | 役割 |
|---|---|
| `lib/services/omi_device_service.dart` | BLE スキャン・接続・特性購読 |
| `lib/services/whisper_streamer.dart` | WS 中継 + WAL バッファ |
| `lib/services/wal_store.dart` | オフライン音声のディスク永続化と HTTP 回収 |
| `lib/services/sdcard_sync_service.dart` | SD カード同期 |
| `lib/services/sdcard_protocol.dart` | ストレージ通知のパーサー（純関数） |
| `lib/services/wifi_sync_service.dart` | WiFi (SoftAP + TCP) 同期 |
| `lib/services/firmware_service.dart` | MCUmgr / Nordic DFU |
| `lib/services/background_service.dart` | foreground service |
| `lib/app_controller.dart` | 各サービスの結線 |

## 依存パッケージ

`flutter_blue_plus` / `web_socket_channel` / `http` /
`flutter_foreground_task` / `permission_handler` / `shared_preferences` /
`path_provider` / `mcumgr_flutter` / `nordic_dfu`

追加禁止: OPUS デコーダ系 (`opus_dart` 等)、分析・決済系 (Firebase, Sentry 等)。
詳細な設計原則は `CLAUDE.md` を参照。
