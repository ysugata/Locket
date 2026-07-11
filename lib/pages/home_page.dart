import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../services/omi_device_service.dart';
import '../services/whisper_streamer.dart';
import '../services/wifi_sync_service.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  final AppController app;
  const HomePage({super.key, required this.app});

  void _openSettings(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SettingsPage(app: app)));
  }

  void _showDebugLog(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DebugLogSheet(app: app),
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
                icon: const Icon(Icons.bug_report),
                tooltip: 'デバッグログ',
                onPressed: () => _showDebugLog(context),
              ),
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
                  if (app.sdCardSync?.isSyncing.value ?? false)
                    _SDSyncCard(app: app),
                  if (app.wifiSync?.isSyncing ?? false) _WifiSyncCard(app: app),
                  const SizedBox(height: 16),
                  _InfoRow(app: app),
                  const SizedBox(height: 16),
                  Text(
                    '直近の文字起こし',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: _TranscriptList(app: app)),
                ],
              ),
            ),
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
    final walMemoryBytes = streamer?.walBufferedBytes ?? 0;
    final walStore = app.walStore;
    final walDiskBytes = walStore?.pendingBytes.value ?? 0;
    final walDiskSegments = walStore?.pendingSegments.value ?? 0;
    final sdSync = app.sdCardSync;
    final sdError = (sdSync?.isSyncing.value ?? false)
        ? null
        : sdSync?.lastError.value;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bluetooth, color: _bleColor(context, bleState)),
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
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (streamer != null) ...[
              const SizedBox(height: 8),
              Text(
                '送信 ${_formatBytes(sent)} / 受信 $received メッセージ'
                '${streamer.gapCount > 0 ? ' / 欠落 ${streamer.totalGapFrames}f' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (streamer.gapCount > 0)
                Text(
                  '⚠ ${streamer.gapCount}回のパケットギャップ検出 (${streamer.totalGapFrames}フレーム欠落)',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 11,
                  ),
                ),
              if (walMemoryBytes > 0 || walDiskSegments > 0)
                Text(
                  '未送信バッファ: メモリ ${_formatBytes(walMemoryBytes)}'
                  '${walDiskSegments > 0 ? ' / ディスク ${_formatBytes(walDiskBytes)} ($walDiskSegmentsセグメント)' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
            if (sdError != null) ...[
              const SizedBox(height: 8),
              Text(
                'SD同期: $sdError',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
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
            if (bleState == OmiConnectionState.disconnected) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: () => app.retryConnect(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('再接続'),
                ),
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
            value: codec >= 0
                ? (codec == omiCodecOpus
                      ? 'OPUS'
                      : (codec == omiCodecOpusFS320
                            ? 'OPUS FS320'
                            : 'id=$codec'))
                : '-',
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
            Text(
              value,
              style: Theme.of(context).textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
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
      return const Center(child: Text('まだ文字起こしがありません'));
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

class _SDSyncCard extends StatelessWidget {
  final AppController app;
  const _SDSyncCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final sync = app.sdCardSync;
    if (sync == null) return const SizedBox.shrink();
    final progress = sync.progress.value;
    final error = sync.lastError.value;
    final transferred = sync.transferredBytes.value;
    final total = sync.totalBytesOnCard;

    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sd_card, size: 20),
                const SizedBox(width: 8),
                Text(
                  'SDカード同期中...',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            if (transferred > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${_StatusCard._formatBytes(transferred)}'
                '${total > 0 ? ' / ${_StatusCard._formatBytes(total)}' : ''} 転送済み',
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
              ),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => sync.cancel(),
              icon: const Icon(Icons.cancel, size: 16),
              label: const Text('キャンセル'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WifiSyncCard extends StatelessWidget {
  final AppController app;
  const _WifiSyncCard({required this.app});

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
    if (sync == null) return const SizedBox.shrink();
    final syncState = sync.state.value;
    final progress = sync.progress.value;
    final speed = sync.speedKBps.value;
    final errorMsg = sync.error.value;

    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi, size: 20),
                const SizedBox(width: 8),
                Text(
                  'WiFi同期: ${_stateLabel(syncState)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            if (speed > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${speed.toStringAsFixed(1)} KB/s',
                style: Theme.of(context).textTheme.bodySmall,
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
              ),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => sync.cancel(),
              icon: const Icon(Icons.cancel, size: 16),
              label: const Text('キャンセル'),
            ),
          ],
        ),
      ),
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

class _DebugLogSheet extends StatelessWidget {
  final AppController app;
  const _DebugLogSheet({required this.app});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return AnimatedBuilder(
          animation: app,
          builder: (context, _) {
            final streamer = app.streamer;
            final entries = streamer?.debugLog.value ?? const <String>[];
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.bug_report),
                      const SizedBox(width: 8),
                      Text(
                        'WS デバッグログ (${entries.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: 'コピー',
                        onPressed: entries.isEmpty
                            ? null
                            : () async {
                                final text = entries.reversed.join('\n');
                                await Clipboard.setData(
                                  ClipboardData(text: text),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('クリップボードにコピー'),
                                    ),
                                  );
                                }
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('まだログがありません'))
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: entries.length,
                          itemBuilder: (_, i) => Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                            child: Text(
                              entries[i],
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
