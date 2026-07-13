import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/firmware_service.dart';
import '../services/wifi_sync_service.dart';
import 'device_selection_page.dart';

class SettingsPage extends StatefulWidget {
  final AppController app;
  const SettingsPage({super.key, required this.app});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _token;
  late String _language;
  late bool _autoReconnect;

  @override
  void initState() {
    super.initState();
    final s = widget.app.settings;
    _baseUrl = TextEditingController(text: s.baseUrl);
    _token = TextEditingController(text: s.authToken);
    _language = s.language;
    _autoReconnect = s.autoReconnect;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = widget.app.settings;
    await s.setBaseUrl(_baseUrl.text);
    await s.setAuthToken(_token.text);
    await s.setLanguage(_language);
    await s.setAutoReconnect(_autoReconnect);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('保存しました')));
  }

  Future<void> _openDeviceSelection() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DeviceSelectionPage(app: widget.app)),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.app.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('サーバー接続', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'ベースURL',
              hintText: 'https://whisper.localai.loan',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            decoration: InputDecoration(
              labelText: '認証トークン',
              border: const OutlineInputBorder(),
              helperText: '現在保存されている値: ${_tokenPreview(settings.authToken)}',
            ),
            autocorrect: false,
            enableSuggestions: false,
            maxLines: 1,
          ),
          const SizedBox(height: 24),
          Text('デバイス', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.bluetooth),
              title: Text(settings.pairedBleName ?? '未ペアリング'),
              subtitle: settings.pairedBleId != null
                  ? Text(settings.pairedBleId!)
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: _openDeviceSelection,
            ),
          ),
          if (settings.pairedBleId != null)
            TextButton(
              onPressed: () async {
                await settings.clearPairedDevice();
                if (mounted) setState(() {});
              },
              child: const Text('ペアリングを解除'),
            ),
          const SizedBox(height: 24),
          Text('録音設定', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('自動再接続'),
            subtitle: const Text('BLE/WebSocket 切断時に自動で再接続する'),
            value: _autoReconnect,
            onChanged: (v) => setState(() => _autoReconnect = v),
          ),
          ListTile(
            title: const Text('言語'),
            trailing: DropdownButton<String>(
              value: _language,
              items: const [
                DropdownMenuItem(value: 'ja', child: Text('日本語 (ja)')),
                DropdownMenuItem(value: 'en', child: Text('English (en)')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _language = v);
              },
            ),
          ),
          const SizedBox(height: 24),
          _SDCardSection(app: widget.app),
          const SizedBox(height: 24),
          // WiFi sync section: only shown when device supports it.
          if (widget.app.wifiSync?.isAvailable ?? false) ...[
            _WifiSyncSection(app: widget.app),
            const SizedBox(height: 24),
          ],
          _FirmwareSection(app: widget.app),
          const SizedBox(height: 24),
          Text('その他', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            title: const Text('デバイスID'),
            subtitle: Text(settings.deviceId),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
    );
  }

  /// Shows first 4 / last 2 chars + length, or "(未設定)". Lets the
  /// user verify that what they just typed matches what's already
  /// persisted, without revealing the full token.
  static String _tokenPreview(String token) {
    if (token.isEmpty) return '(未設定)';
    if (token.length <= 6) return '${token.length}文字';
    return '${token.substring(0, 4)}…${token.substring(token.length - 2)} (${token.length}文字)';
  }
}

class _WifiSyncSection extends StatelessWidget {
  final AppController app;
  const _WifiSyncSection({required this.app});

  String _stateLabel(WifiSyncState s) {
    switch (s) {
      case WifiSyncState.idle:
        return '待機中';
      case WifiSyncState.settingUp:
        return 'AP設定中...';
      case WifiSyncState.connecting:
        return 'WiFi接続中...';
      case WifiSyncState.transferring:
        return 'データ転送中...';
      case WifiSyncState.uploading:
        return 'アップロード中...';
      case WifiSyncState.done:
        return '完了';
      case WifiSyncState.error:
        return 'エラー';
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = app.wifiSync;
    final isAvailable = sync?.isAvailable ?? false;
    final syncState = sync?.state.value ?? WifiSyncState.idle;
    final syncing = sync?.isSyncing ?? false;
    final progress = sync?.progress.value ?? 0.0;
    final speed = sync?.speedKBps.value ?? 0.0;
    final errorMsg = sync?.error.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('WiFi同期', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isAvailable)
                  const Text('デバイスがWiFi同期に対応していません')
                else ...[
                  Text('状態: ${_stateLabel(syncState)}'),
                  if (syncing) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          '${(progress * 100).toStringAsFixed(1)}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (speed > 0) ...[
                          const Spacer(),
                          Text(
                            '${speed.toStringAsFixed(1)} KB/s',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (errorMsg != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorMsg,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: syncing ? null : () => app.syncWifi(),
                        icon: const Icon(Icons.wifi),
                        label: const Text('WiFi同期を開始'),
                      ),
                      if (syncing) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => sync?.cancel(),
                          child: const Text('キャンセル'),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FirmwareSection extends StatefulWidget {
  final AppController app;
  const _FirmwareSection({required this.app});

  @override
  State<_FirmwareSection> createState() => _FirmwareSectionState();
}

class _FirmwareSectionState extends State<_FirmwareSection> {
  FirmwareService? get _fw => widget.app.firmwareService;

  Future<void> _check() async {
    final fw = _fw;
    if (fw == null) return;
    await fw.checkLatest();
    if (mounted) setState(() {});
  }

  Future<void> _download() async {
    final fw = _fw;
    if (fw == null || fw.latestInfo == null) return;
    await fw.download(fw.latestInfo!);
    if (mounted) setState(() {});
  }

  Future<void> _install() async {
    final fw = _fw;
    final zipPath = fw?.downloadedZipPath;
    if (fw == null || zipPath == null || !fw.canInstall) return;
    final deviceId = widget.app.settings.pairedBleId;
    if (deviceId == null) return;

    // Updating wipes the device's SD storage, and 3.0.20+ speaks the
    // new ring protocol this app doesn't support yet — make both
    // consequences explicit before flashing.
    final targetVersion = fw.latestInfo?.version ?? '';
    final isRingFirmware = _versionAtLeast(targetVersion, '3.0.20');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ファームウェア更新'),
        content: Text(
          '更新するとデバイスのSDストレージは消去されます。'
          '未同期の録音（SDに残っているもの）はすべて失われます。\n'
          '${isRingFirmware ? '\n⚠ $targetVersion は新しいリング方式の'
                    'ストレージプロトコルです。Locket が対応するまで '
                    'SD同期は動作しません（ライブ文字起こしは影響ありません）。\n' : ''}'
          '\n続行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('更新する'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // Disable auto-reconnect during DFU — disconnect is expected.
    widget.app.device.enableAutoReconnect(false);

    try {
      await fw.performUpdate(
        deviceId,
        zipPath,
        hasSmpService: widget.app.device.hasSmpService.value,
      );
    } finally {
      // Restore auto-reconnect so the device links back up after it
      // reboots into the new firmware.
      widget.app.device.enableAutoReconnect(widget.app.settings.autoReconnect);
    }
    if (mounted) setState(() {});
  }

  /// Compare dotted versions: true when [v] >= [min].
  static bool _versionAtLeast(String v, String min) {
    List<int> parse(String s) =>
        s.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final a = parse(v);
    final b = parse(min);
    for (var i = 0; i < b.length; i++) {
      final ai = i < a.length ? a[i] : 0;
      if (ai != b[i]) return ai > b[i];
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final fw = _fw;
    final currentVersion = widget.app.device.firmwareVersion.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ファームウェア', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: fw == null
                ? const Text('デバイスに接続してからアップデートを確認できます')
                : _buildContent(context, fw, currentVersion),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    FirmwareService fw,
    String currentVersion,
  ) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        fw,
        fw.isChecking,
        fw.isDownloading,
        fw.isInstalling,
        fw.installComplete,
        fw.downloadProgress,
        fw.installProgress,
        fw.error,
      ]),
      builder: (context, _) {
        final checking = fw.isChecking.value;
        final downloading = fw.isDownloading.value;
        final installing = fw.isInstalling.value;
        final complete = fw.installComplete.value;
        final dlProgress = fw.downloadProgress.value;
        final instProgress = fw.installProgress.value;
        final errorMsg = fw.error.value;
        final latest = fw.latestInfo;
        final onLatest =
            latest != null &&
            currentVersion.isNotEmpty &&
            currentVersion == latest.version;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '現在のバージョン: '
              '${currentVersion.isEmpty ? "不明" : currentVersion}',
            ),
            if (latest != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('最新バージョン: ${latest.version}')),
                  if (onLatest)
                    Row(
                      children: [
                        Icon(Icons.check_circle, size: 16, color: Colors.green),
                        const SizedBox(width: 4),
                        Text(
                          '最新です',
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: Colors.green),
                        ),
                      ],
                    ),
                ],
              ),
              if (latest.releaseNotes != null &&
                  latest.releaseNotes!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  latest.releaseNotes!,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
            if (complete && !installing) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.check_circle, size: 18, color: Colors.green),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'インストール完了。デバイスが再起動して新しい'
                      'ファームウェアで接続し直します',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            if (errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMsg,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (downloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: dlProgress / 100),
              const SizedBox(height: 4),
              Text(
                'ダウンロード中... $dlProgress%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (installing) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: instProgress / 100),
              const SizedBox(height: 4),
              Text(
                'インストール中... $instProgress%'
                '（完了までアプリを閉じず、デバイスを近くに置いてください）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!downloading && !installing)
                  FilledButton.tonalIcon(
                    onPressed: checking ? null : _check,
                    icon: checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: const Text('アップデートを確認'),
                  ),
                // Download only when there's a genuinely newer version
                // and nothing is downloaded/in-flight yet.
                if (latest != null &&
                    !onLatest &&
                    !complete &&
                    !fw.hasDownloadedFirmware &&
                    !downloading &&
                    !installing)
                  FilledButton.tonalIcon(
                    onPressed: _download,
                    icon: const Icon(Icons.download),
                    label: const Text('ダウンロード'),
                  ),
                // Install only while a fresh download is ready and the
                // device isn't already on that version.
                if (fw.canInstall && !onLatest)
                  FilledButton.icon(
                    onPressed: _install,
                    icon: const Icon(Icons.system_update),
                    label: const Text('インストール'),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _SDCardSection extends StatelessWidget {
  final AppController app;
  const _SDCardSection({required this.app});

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final sync = app.sdCardSync;
    final syncing = sync?.isSyncing.value ?? false;
    final progress = sync?.progress.value ?? 0.0;
    final error = sync?.lastError.value;
    final totalBytes = sync?.totalBytesOnCard ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SDカード同期', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('カード上のデータ: ${_formatBytes(totalBytes)}'),
                if (syncing) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 4),
                  Text(
                    '${(progress * 100).toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: sync == null || syncing
                          ? null
                          : () => app.syncSDCard(),
                      icon: const Icon(Icons.sync),
                      label: const Text('今すぐ同期'),
                    ),
                    if (syncing) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => sync?.cancel(),
                        child: const Text('キャンセル'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: sync == null || syncing
                      ? null
                      : () => _confirmRescue(context),
                  icon: const Icon(Icons.medical_services_outlined),
                  label: const Text('レスキュー同期（SDが応答しない時）'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmRescue(BuildContext context) async {
    // A near-empty card needs no rescue — say so instead of offering
    // a destructive flow that has nothing to recover.
    final sdBytes = app.sdCardSync?.totalBytesOnCard ?? -1;
    if (sdBytes >= 0 && sdBytes < 1024 * 1024) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('レスキュー同期'),
          content: Text(
            'SDカードはほぼ空です（${sdBytes}B）。\n'
            'レスキューは不要で、同期するデータもありません。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('閉じる'),
            ),
          ],
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('レスキュー同期'),
        content: const Text(
          'SDカードが満杯で応答しない場合の復旧モードです。\n\n'
          '・実行中はリアルタイム文字起こしが一時停止します\n'
          '・読み出せないファイルを最大5件（最古のもの、合計約25MB＝'
          '90分程度の録音）を削除して空き容量を作ります。'
          'この削除は元に戻せません\n'
          '・空きができ次第、残りの録音をすべて吸い上げます\n\n'
          '数時間かかることがあります。就寝中などの実行がおすすめです。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('実行する'),
          ),
        ],
      ),
    );
    if (ok == true) {
      app.rescueSDCard();
    }
  }
}
