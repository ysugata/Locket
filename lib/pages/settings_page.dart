import 'package:flutter/material.dart';

import '../app_controller.dart';
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('保存しました')),
    );
  }

  Future<void> _openDeviceSelection() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceSelectionPage(app: widget.app),
      ),
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
              helperText:
                  '現在保存されている値: ${_tokenPreview(settings.authToken)}',
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
          Text('その他', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            title: const Text('デバイスID'),
            subtitle: Text(settings.deviceId),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
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
                  Text('${(progress * 100).toStringAsFixed(1)}%',
                      style: Theme.of(context).textTheme.bodySmall),
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
              ],
            ),
          ),
        ),
      ],
    );
  }
}
