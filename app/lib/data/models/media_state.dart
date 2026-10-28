/// Estado de una radio (Bluetooth o Wi-Fi). `transitioning` cubre los estados
/// intermedios de Android (`TURNING_ON`/`TURNING_OFF`, `ENABLING`/`DISABLING`).
enum RadioState {
  off,
  transitioning,
  on;

  static RadioState parse(Object? value) => switch (value) {
        'on' || true => RadioState.on,
        'transitioning' => RadioState.transitioning,
        _ => RadioState.off,
      };
}

/// Snapshot del estado de los medios que usa Nearby Connections.
class MediaState {
  final RadioState bluetooth;
  final RadioState wifi;
  final bool location;
  final bool airplane;

  const MediaState({
    required this.bluetooth,
    required this.wifi,
    required this.location,
    required this.airplane,
  });

  factory MediaState.fromMap(Map<dynamic, dynamic> map) => MediaState(
        bluetooth: RadioState.parse(map['bluetooth']),
        wifi: RadioState.parse(map['wifi']),
        location: map['location'] == true,
        airplane: map['airplane'] == true,
      );

  bool get bluetoothOn => bluetooth == RadioState.on;
  bool get wifiOn => wifi == RadioState.on;

  /// Ninguna radio está en transición: se puede decidir con este snapshot.
  bool get stable =>
      bluetooth != RadioState.transitioning && wifi != RadioState.transitioning;

  /// Ni Bluetooth ni Wi-Fi encendidos: no queda ningún canal para Nearby.
  bool get noTransport => !bluetoothOn && !wifiOn;

  @override
  bool operator ==(Object other) =>
      other is MediaState &&
      other.bluetooth == bluetooth &&
      other.wifi == wifi &&
      other.location == location &&
      other.airplane == airplane;

  @override
  int get hashCode => Object.hash(bluetooth, wifi, location, airplane);

  @override
  String toString() =>
      'MediaState(bt=${bluetooth.name}, wifi=${wifi.name}, loc=$location, airplane=$airplane)';
}
