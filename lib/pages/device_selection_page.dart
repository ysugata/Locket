import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/omi_discovered_device.dart';

class DeviceSelectionPage extends StatefulWidget {
  final AppController app;
  const DeviceSelectionPage({super.key, required this.app});

  @override
  State<DeviceSelectionPage> createState() => _DeviceSelectionPageState();
}

class _DeviceSelectionPageState extends State<DeviceSelectionPage> {
  bool _scanning = false;
  List<OmiDiscoveredDevice> _devices = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final results = await widget.app.device.scanForDevices();
      if (!mounted) return;
      setState(() => _devices = results);
    } catch (e) {
      if (!mounted) return;
      // Strip "Bad state: " / "StateError: " prefix that Dart adds to
      // toString() so the Japanese message reaches the user cleanly.
      final raw = e.toString();
      final clean = raw
          .replaceFirst('Bad state: ', '')
          .replaceFirst('StateError: ', '');
      setState(() => _error = clean);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pair(OmiDiscoveredDevice device) async {
    await widget.app.settings.setPairedDevice(id: device.id, name: device.name);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('デバイスを選択'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _scanning ? null : _startScan,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_scanning) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'エラー: $_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _devices.isEmpty && !_scanning
                ? const Center(child: Text('デバイスが見つかりません'))
                : ListView.separated(
                    itemCount: _devices.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final d = _devices[i];
                      return ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text(d.name),
                        subtitle: Text(d.id),
                        trailing: Text('${d.rssi} dBm'),
                        onTap: () => _pair(d),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
