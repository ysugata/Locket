class OmiDiscoveredDevice {
  final String id;
  final String name;
  final int rssi;

  const OmiDiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OmiDiscoveredDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
