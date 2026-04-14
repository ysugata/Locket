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
          floatingActionButton: FloatingActionButton.extended(
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
    final wsState = app.streamer?.connectionState.value ??
        WhisperConnectionState.disconnected;

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
          ],
        ),
      ),
    );
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
