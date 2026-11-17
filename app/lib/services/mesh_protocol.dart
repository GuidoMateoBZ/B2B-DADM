/// Protocolo entre la UI y el servicio de fondo (`flutter_background_service`).
///
/// La UI manda comandos y el servicio responde con eventos. Los nombres y la
/// forma de los mapas viven solo acá.
library;

/// Estados posibles de la red tal como los ve la UI.
/// `noMedia` (sin Bluetooth ni Wi-Fi) y `noLocation` (ubicación apagada y sin
/// vecinos) son pausas automáticas: la red se reanuda sola al volver el medio.
/// `disconnecting` solo existe en la UI: se pidió el cierre y se espera la
/// confirmación del servicio.
enum NearbyState {
  idle,
  disconnecting,
  searching,
  connecting,
  connected,
  error,
  noMedia,
  noLocation,
}

/// Comandos UI → servicio.
abstract final class MeshCommand {
  /// `{nodeId: String, uiState: Map?}`
  static const startSearch = 'start_search';
  static const stopSearch = 'stop_search';

  /// `{endpointId: String}`
  static const disconnectEndpoint = 'disconnect_endpoint';

  /// `{envelope: String}` (Envelope codificado)
  static const sendEnvelope = 'send_envelope';

  /// [UiPresence.toMap]
  static const uiState = 'ui_state';
  static const requestSnapshot = 'request_snapshot';
}

/// Eventos servicio → UI.
abstract final class MeshEvent {
  /// [MeshSnapshot.toMap]
  static const snapshot = 'mesh_snapshot';

  /// `{messageId: String}`: se guardó un mensaje entrante en la base.
  static const messagesChanged = 'messages_changed';

  /// El servicio terminó de inicializarse (o respondió a `request_snapshot`).
  static const serviceReady = 'service_ready';

  /// Se emite justo antes de `stopSelf()`.
  static const serviceStopped = 'service_stopped';
}

/// Qué está mirando la UI: decide si el servicio notifica un mensaje.
class UiPresence {
  final bool foreground;
  final String? chatNodeId;
  final bool broadcastVisible;

  const UiPresence({
    this.foreground = false,
    this.chatNodeId,
    this.broadcastVisible = false,
  });

  factory UiPresence.fromMap(Map<dynamic, dynamic> map) => UiPresence(
    foreground: map['foreground'] == true,
    chatNodeId: map['chatNodeId'] is String
        ? map['chatNodeId'] as String
        : null,
    broadcastVisible: map['broadcastVisible'] == true,
  );

  Map<String, dynamic> toMap() => {
    'foreground': foreground,
    'chatNodeId': chatNodeId,
    'broadcastVisible': broadcastVisible,
  };
}

/// Endpoint descubierto tal como viaja en el snapshot.
typedef SnapshotEndpoint = ({String endpointId, String userName});

/// Estado completo de la red que el servicio publica tras cada cambio.
class MeshSnapshot {
  final NearbyState state;
  final bool searching;
  final String? myNodeId;
  final String? errorMessage;
  final List<SnapshotEndpoint> discovered;

  /// endpointId → nodeId
  final Map<String, String> connected;
  final List<String> connecting;

  /// Hay un cierre en curso o terminado (hasta que el servicio muera o llegue
  /// un inicio nuevo).
  final bool stopping;

  /// El último cierre no se pudo confirmar: el servicio sigue vivo.
  final bool stopFailed;

  const MeshSnapshot({
    required this.state,
    this.searching = false,
    this.myNodeId,
    this.errorMessage,
    this.discovered = const [],
    this.connected = const {},
    this.connecting = const [],
    this.stopping = false,
    this.stopFailed = false,
  });

  Map<String, dynamic> toMap() => {
    'state': state.name,
    'searching': searching,
    'myNodeId': myNodeId,
    'errorMessage': errorMessage,
    'discovered': [
      for (final e in discovered)
        {'endpointId': e.endpointId, 'userName': e.userName},
    ],
    'connected': Map<String, String>.from(connected),
    'connecting': List<String>.from(connecting),
    'stopping': stopping,
    'stopFailed': stopFailed,
  };

  /// Tolera campos ausentes o con tipo inesperado (los descarta).
  factory MeshSnapshot.fromMap(Map<dynamic, dynamic> map) {
    String? str(Object? v) => v is String ? v : null;
    return MeshSnapshot(
      state: NearbyState.values.firstWhere(
        (s) => s.name == map['state'],
        orElse: () => NearbyState.error,
      ),
      searching: map['searching'] == true,
      myNodeId: str(map['myNodeId']),
      errorMessage: str(map['errorMessage']),
      discovered: [
        for (final entry
            in map['discovered'] is List ? map['discovered'] as List : const [])
          if (entry is Map &&
              entry['endpointId'] is String &&
              entry['userName'] is String)
            (
              endpointId: entry['endpointId'] as String,
              userName: entry['userName'] as String,
            ),
      ],
      connected: {
        if (map['connected'] is Map)
          for (final e in (map['connected'] as Map).entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
      },
      connecting: [
        for (final id
            in map['connecting'] is List ? map['connecting'] as List : const [])
          if (id is String) id,
      ],
      stopping: map['stopping'] == true,
      stopFailed: map['stopFailed'] == true,
    );
  }
}
