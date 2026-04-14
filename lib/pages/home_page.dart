import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/omi_device_service.dart';
import '../services/whisper_streamer.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  final AppController app;
  const HomePage({super.key, required this.app});

  Future<void> _toggle(BuildContext context) async {
    if (app.running) {
      await app.stop();
    } else {
      await app.start();
      final err = app.lastError;
      if (err != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err)),
        );
      }
    }
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(app: app)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        app,
        app.settings,
        app.device.connectionState,
        app.device.batteryLevel,
        app.device.codecId,
        app.device.firmwareVersion,
      ]),
      builder: (context, _) {
        final settings = app.settings;
        final needsToken = settings.authToken.isEmpty;
        final needsDevice =
            settings.pairedBleId == null || settings.pairedBleId!.isEmpty;
        final needsSetup = needsToken || needsDevice;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Locket'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => _openSettings(context),
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (needsSetup)
                    _SetupCard(
                      needsToken: needsToken,
                      needsDevice: needsDevice,
                      onOpenSettings: () => _openSettings(context),
                    )
                  else
                    _StatusCard(app: app),
                  const SizedBox(height: 16),
                  _InfoRow(app: app),
                  const SizedBox(height: 16),
                  Text('直近の文字起こし',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Expanded(child: _TranscriptList(app: app)),
                ],
              ),
            ),
          ),
          floatingActionButton: needsSetup
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _toggle(context),
                  icon: Icon(app.running ? Icons.stop : Icons.play_arrow),
                  label: Text(app.running ? '停止' : '開始'),
                ),
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  final AppController app;
  const _StatusCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final bleState = app.device.connectionState.value;
    final streamer = app.streamer;
    final wsState =
        streamer?.connectionState.value ?? WhisperConnectionState.disconnected;
    // Combine errors from the AppController (start/stop, BLE permission,
    // missing settings) and the WhisperStreamer (WS handshake, close).
    final wsError = streamer?.lastError.value;
    final controllerError = app.lastError;
    final displayError = wsError ?? controllerError;
    final sent = streamer?.bytesSent.value ?? 0;
    final received = streamer?.messagesReceived.value ?? 0;
    final uri = streamer?.lastUri;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bluetooth,
                    color: _bleColor(context, bleState)),
                const SizedBox(width: 8),
                Text('BLE: ${_bleLabel(bleState)}'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.cloud, color: _wsColor(context, wsState)),
                const SizedBox(width: 8),
                Text('WebSocket: ${_wsLabel(wsState)}'),
              ],
            ),
            if (uri != null) ...[
              const SizedBox(height: 8),
              Text(
                _redactToken(uri),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (streamer != null) ...[
              const SizedBox(height: 8),
              Text(
                '送信 ${_formatBytes(sent)} / 受信 $received メッセージ',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (displayError != null) ...[
              const SizedBox(height: 8),
              Text(
                'エラー: $displayError',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the displayed URL by hand instead of going through
  /// `Uri.toString()` after replacing query parameters — that path
  /// percent-encodes the redaction characters (e.g. `*` → `%2A`)
  /// and the result becomes unreadable.
  static String _redactToken(Uri uri) {
    final origin =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path}';
    final parts = <String>[];
    uri.queryParameters.forEach((k, v) {
      if (k == 'token') {
        final masked = v.length <= 6 ? 'xxx' : '${v.substring(0, 3)}…';
        parts.add('$k=$masked');
      } else {
        parts.add('$k=$v');
      }
    });
    return parts.isEmpty ? origin : '$origin?${parts.join('&')}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)}MB';
  }

  Color _bleColor(BuildContext context, OmiConnectionState s) {
    final scheme = Theme.of(context).colorScheme;
    switch (s) {
      case OmiConnectionState.connected:
        return Colors.green;
      case OmiConnectionState.connecting:
      case OmiConnectionState.reconnecting:
      case OmiConnectionState.scanning:
        return Colors.orange;
      case OmiConnectionState.disconnected:
        return scheme.outline;
    }
  }

  String _bleLabel(OmiConnectionState s) {
    switch (s) {
      case OmiConnectionState.connected:
        return '接続中';
      case OmiConnectionState.connecting:
        return '接続試行中';
      case OmiConnectionState.reconnecting:
        return '再接続中';
      case OmiConnectionState.scanning:
        return 'スキャン中';
      case OmiConnectionState.disconnected:
        return '未接続';
    }
  }

  Color _wsColor(BuildContext context, WhisperConnectionState s) {
    final scheme = Theme.of(context).colorScheme;
    switch (s) {
      case WhisperConnectionState.connected:
        return Colors.green;
      case WhisperConnectionState.connecting:
      case WhisperConnectionState.reconnecting:
        return Colors.orange;
      case WhisperConnectionState.disconnected:
        return scheme.outline;
    }
  }

  String _wsLabel(WhisperConnectionState s) {
    switch (s) {
      case WhisperConnectionState.connected:
        return '接続中';
      case WhisperConnectionState.connecting:
        return '接続試行中';
      case WhisperConnectionState.reconnecting:
        return '再接続中';
      case WhisperConnectionState.disconnected:
        return '未接続';
    }
  }
}

class _InfoRow extends StatelessWidget {
  final AppController app;
  const _InfoRow({required this.app});

  @override
  Widget build(BuildContext context) {
    final battery = app.device.batteryLevel.value;
    final codec = app.device.codecId.value;
    final fw = app.device.firmwareVersion.value;

    return Row(
      children: [
        Expanded(
          child: _InfoTile(
            icon: Icons.battery_full,
            label: 'バッテリー',
            value: battery >= 0 ? '$battery%' : '-',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _InfoTile(
            icon: Icons.music_note,
            label: 'コーデック',
            value: codec >= 0 ? (codec == 20 ? 'OPUS' : 'id=$codec') : '-',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _InfoTile(
            icon: Icons.memory,
            label: 'ファームウェア',
            value: fw.isEmpty ? '-' : fw,
          ),
        ),
      ],
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, size: 20),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(value,
                style: Theme.of(context).textTheme.titleSmall,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _TranscriptList extends StatelessWidget {
  final AppController app;
  const _TranscriptList({required this.app});

  @override
  Widget build(BuildContext context) {
    final items = app.transcripts;
    if (items.isEmpty) {
      return const Center(
        child: Text('まだ文字起こしがありません'),
      );
    }
    return ListView.builder(
      reverse: true,
      itemCount: items.length,
      itemBuilder: (_, i) {
        final seg = items[items.length - 1 - i];
        return ListTile(
          dense: true,
          title: Text(seg.text),
          subtitle: Text(
            '${seg.start.toStringAsFixed(1)}s → ${seg.end.toStringAsFixed(1)}s',
          ),
        );
      },
    );
  }
}

class _SetupCard extends StatelessWidget {
  final bool needsToken;
  final bool needsDevice;
  final VoidCallback onOpenSettings;
  const _SetupCard({
    required this.needsToken,
    required this.needsDevice,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: scheme.onPrimaryContainer),
                const SizedBox(width: 8),
                Text(
                  'セットアップが必要です',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (needsToken)
              _SetupStep(
                color: scheme.onPrimaryContainer,
                text: '1. サーバーの認証トークンを入力',
              ),
            if (needsDevice)
              _SetupStep(
                color: scheme.onPrimaryContainer,
                text: needsToken
                    ? '2. Omi CV1 をスキャンしてペアリング'
                    : '1. Omi CV1 をスキャンしてペアリング',
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings),
              label: const Text('設定を開く'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupStep extends StatelessWidget {
  final Color color;
  final String text;
  const _SetupStep({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}
