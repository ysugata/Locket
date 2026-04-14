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
            decoration: const InputDecoration(
              labelText: '認証トークン',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            autocorrect: false,
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
}
