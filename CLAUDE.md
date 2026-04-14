# CLAUDE.md

このリポジトリは Omi CV1 BLEウェアラブルデバイスから音声を取得し、自前の
Whisperサーバー (`wss://whisper.localai.loan`) へ **OPUS生バイトのまま** 転送する
Flutterアプリ (iOS優先 / Android対応) です。

実装計画の詳細は `docs/INSTRUCTIONS.md` を参照。このファイルはプロジェクトの
恒久的なルール・ガードレールのみを記載します。

## 言語

- ユーザーへの応答（サマリー、説明、確認など）は **すべて日本語** で行うこと
- コード中のコメント、識別子、コミットメッセージは英語で統一

## プロジェクトの絶対原則

### 1. アプリはOPUSをデコードしない

- `opus_dart` / `flutter_opus` 等のOPUSデコーダパッケージは **追加禁止**
- BLE Notify で受け取ったバイトは中身を一切いじらず WS に送る
- 「文字起こしの内容がおかしい」等の問題はサーバー側で調査する。アプリ側で
  デコード処理を足して解決しようとしない

### 2. 3バイトヘッダの処理はサーバー責務

- Omiパケット先頭の `[packet_id_low, packet_id_high, fragment_index]`
  3バイトヘッダは **剥がさずに送信** する
- ユーザーの `omi_whisper_bridge.py` は接続URLの `frame_header=3byte`
  クエリでこの形式を期待し、受信後に剥がして OPUS デコードを行う
- フラグメント再構築もサーバー側で行う。アプリは流すだけ
- BasedHardware/omi 公式クライアントは `getSocketPayload` で剥がしているが、
  これは omi 公式バックエンドの仕様。**Locket はユーザーの bridge
  に合わせる** (剥がさない)

### 3. iOS優先 / Android共通コード

- 動作検証は **iOS実機のみ**
- Android は `flutter build apk` がエラーなく通ることだけ保証する
- BLE層・WebSocket層・SD同期層・UI層は **共通コード** で書く
- `Platform.isIOS` / `Platform.isAndroid` 分岐を許すのは
  **起動時の権限要求フロー** と **バックグラウンドサービス初期化** のみ

### 4. サーバー側仕様の遵守

既存の `omi_whisper_bridge.py` の実装を勝手に推測で変えない:

- WebSocket 接続先は **ルートパス `/`**
- 認証は **`?token=<AUTH_TOKEN>` クエリのみ** (Bearerヘッダは bridge が
  読まないので送らない)
- **`?codec=opus` と `?frame_header=3byte` は両方必須**。どちらか欠けると
  bridge は 4400 で切断する
- ハンドシェイク無し。接続したら即 binary フレームを送り始める
  (`{"type":"ready"}` のような交換は **しない**)
- データ送信: WS binary フレームに **Omi 3バイトヘッダ + 生 OPUS
  ペイロード** をそのまま流す
- サーバー → クライアント: セグメント確定時に `{"segments":[...]}` JSON
  テキストのみ。ping/keepalive の特別な仕掛けは無い
  (WS プロトコルレベルの ping は `IOWebSocketChannel.pingInterval` で OK)
- SDカード一括アップロード: `POST /sdcard/upload?token=X&codec=opus&frame_header=3byte`
  body は OPUS フレーム連結

## Git ワークフロー

### Worktree ベースの並列開発

ソースを書き換える場合は **git worktree** を使い、メインの作業ディレクトリを
汚さずに並列開発する。

```bash
# 1. まず main を最新化（古い main から分岐しないように）
git fetch origin main

# 2. worktree を作成（ベースブランチを明示）
git worktree add ../locket-<機能名> -b <branch名> origin/main
# 例: git worktree add ../locket-ble-layer -b feature/ble-layer origin/main

# 3. worktree 内で開発・テスト・コミット・プッシュ

# 4. マージ後にクリーンアップ
git worktree remove ../locket-<機能名>
git branch -d <branch名>
git push origin --delete <branch名>
```

### ブランチルール

- ブランチ名は内容に応じて `feature/xxx` や `fix/xxx` 等、適切に決める
- `main` に直接コミットしない
- 作業完了後はコミット＆プッシュし、特に指示がなければ `main` にマージする
- マージ後は `main` にチェックアウトして pull し、最新の状態にしておく
- マージ完了後はローカル・リモート両方のブランチを削除する
- worktree のディレクトリも削除する (`git worktree remove`)

## テスト — 必須ステップ

コードを修正・追加した場合、コミット前に以下をすべて実行すること。
「ビルドが通った ≠ 動作確認」。Flutter は特に型チェックが緩いので、
静的解析通過だけでは不十分。

### Step 1: 静的解析

```bash
flutter analyze
dart format --set-exit-if-changed lib/ test/
```

警告ゼロで通ること。警告を `// ignore:` で潰すのは最終手段。

### Step 2: ユニットテスト

- 変更したクラス・関数の `flutter test` を実行
- 既存テストがない場合は最低限のテストを書く (特にパーサー系・エンコーダ系)
- BLE/WebSocket/HTTP は mock で単体テスト可能にする

```bash
flutter test
```

### Step 3: 両OSビルド確認

iOSとAndroid両方のビルドが通ることをコミット前に確認。片方だけで
コミットすると後で直すのが高コスト。

```bash
flutter build ios --debug --no-codesign
flutter build apk --debug
```

両方がエラーなく完了すること。

### Step 4: iOS実機での結合テスト

変更内容に応じて以下のチェックを行う (シミュレータではBLEが動かないため実機必須):

#### BLE層 (`omi_device_service.dart`) を変更した場合

1. iPhone実機で `flutter run --release` を実行
2. Omi CV1 をスキャン → ペアリング → 接続できることを確認
3. バッテリー残量・ファームウェアバージョンが表示されることを確認
4. Audio Stream が流れ始めることをログで確認
5. 切断 → 自動再接続が動くことを確認

#### WebSocket層 (`whisper_streamer.dart`) を変更した場合

1. iPhone実機でアプリ起動 → デバイス接続
2. サーバーの Web UI で文字起こしが流れることを確認
3. 30秒以上無音を流して keep-alive が切断されないことを確認
4. サーバー再起動 → 自動再接続が動くことを確認

#### SDカード同期層 (`sdcard_sync_service.dart`) を変更した場合

1. Omi CV1 にしばらく録音 → SDにOPUSフレームを溜める
2. アプリから同期実行 → プログレスバーが進捗することを確認
3. サーバー `/sdcard/upload` が受信し、文字起こし結果が生成されることを確認
4. 成功後、SDがクリアされることを確認

#### バックグラウンド継続録音 (`background_service.dart`) を変更した場合

1. アプリ起動 → デバイス接続 → 文字起こし流れを確認
2. 画面ロック → 30分放置
3. サーバー側で文字起こしが継続していることを確認
4. アプリ復帰 → ログでエラーが出ていないことを確認

#### UI (`pages/`, `widgets/`) を変更した場合

1. iPhone実機で `flutter run` を実行
2. ライト/ダーク両モードで表示崩れがないことを確認
3. 変更した画面の全インタラクションを手動で動かす

### Step 5: Androidビルド確認のみ

実機検証はしないが、`flutter build apk --debug` が通ること。通らない場合は
iOS実装を進めず先に直す。

### テスト不合格時

- テストが通らない状態では **絶対にコミットしない**
- 結合テストで問題が見つかった場合、修正してから再テスト

## ドキュメント

- 機能追加・変更・削除を行った場合、`README.md` も合わせて更新すること
- 更新対象: 機能一覧、設定項目、画面構成、ビルド手順、依存パッケージ一覧など
- コミットに README の更新を含める（別コミットにしない）
- `docs/INSTRUCTIONS.md` (実装計画書) は歴史ドキュメントとして保持。
  実装途中で計画からズレた場合は `INSTRUCTIONS.md` ではなく `README.md` と
  `CLAUDE.md` を更新する

## 設計方針

### アーキテクチャ

- アプリは「BLE → サーバー転送」の薄い中継に徹する。
  文字起こし保存・UI閲覧・要約・AIチャット等の機能は一切持たない
- サーバー側の仕様変更に追随するのはアプリ側の責務。勝手にクライアント側で
  互換レイヤーを作らない
- 設定は `baseUrl` + `authToken` の2項目のみ。WebSocket URL と SDアップロード URL
  は `baseUrl` から組み立てる

### 依存パッケージの方針

- 追加するパッケージは **iOS/Android両対応** のものを選ぶ
- `flutter_foreground_task` / `permission_handler` / `flutter_blue_plus` は両対応
- `omi_sdk` が片方でしか動かない場合は `flutter_blue_plus` にフォールバック
- **追加禁止**: `opus_dart`, `flutter_opus`, その他のOPUSデコーダ系
- **追加禁止**: Firebase / Mixpanel / Sentry / Bugsnag / Stripe 等の分析・決済系

### プラットフォーム固有コードの最小化

`Platform.isIOS` / `Platform.isAndroid` の分岐は以下に限定:

- 起動時の権限要求 (iOS: Bluetooth, Microphone / Android: BLUETOOTH_SCAN,
  POST_NOTIFICATIONS)
- `FlutterForegroundTask.init()` の `androidNotificationOptions` /
  `iosNotificationOptions`

BLE層・WebSocket層・SD同期層・UI層には **分岐を書かない**。

### 状態管理

- `ChangeNotifier` + `ValueNotifier` の組み合わせで軽量に保つ
- Provider/Riverpod/Bloc 等の大型ステート管理ライブラリは入れない
- 小規模アプリなので `setState` と `ChangeNotifier` で十分

### エラーハンドリング

- BLE切断 / WebSocket切断 / HTTP失敗は **自動再接続** で吸収する
  (ユーザーへのエラー表示は最後の手段)
- WAL (Write-Ahead Log) バッファでオフライン中の音声を保持し、
  再接続時にフラッシュする
- クラッシュログ収集サービス (Sentry等) は入れない。ログは stdout のみ
