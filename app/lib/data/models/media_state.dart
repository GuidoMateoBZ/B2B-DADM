/// Snapshot del estado de los medios que usa Nearby Connections.
class MediaState {
  final bool bluetooth;
  final bool wifi;
  final bool location;
  final bool airplane;

  const MediaState({
    required this.bluetooth,
    required this.wifi,
    required this.location,
    required this.airplane,
  });

  factory MediaState.fromMap(Map<dynamic, dynamic> map) => MediaState(
        bluetooth: map['bluetooth'] == true,
        wifi: map['wifi'] == true,
        location: map['location'] == true,
        airplane: map['airplane'] == true,
      );

  /// Ni Bluetooth ni Wi-Fi: no queda ningún canal para Nearby.
  bool get noTransport => !bluetooth && !wifi;

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
      'MediaState(bt=$bluetooth, wifi=$wifi, loc=$location, airplane=$airplane)';
}
