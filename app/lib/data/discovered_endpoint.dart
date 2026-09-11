/// Representa un dispositivo descubierto por Nearby Connections.
class DiscoveredEndpoint {
  /// ID asignado por Nearby Connections para este endpoint.
  final String endpointId;

  /// Nombre visible del dispositivo (el Node ID que anunció).
  final String userName;

  DiscoveredEndpoint({
    required this.endpointId,
    required this.userName,
  });
}
