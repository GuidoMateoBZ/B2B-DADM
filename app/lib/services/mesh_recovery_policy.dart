import '../data/models/media_state.dart';

/// Acción que el provider debe ejecutar tras evaluar un cambio de medios.
enum MediaDecision {
  /// No hace falta hacer nada.
  none,

  /// Ni Bluetooth ni Wi-Fi: detener todo y avisar (`noMedia`).
  pauseNoMedia,

  /// Ubicación apagada: detener solo el discovery y preservar enlaces/advertising.
  pauseDiscovery,

  /// Nearby no estaba en marcha y hay medios: iniciar advertising + discovery.
  start,

  /// El Bluetooth se reinició: `stopAll` + iniciar de nuevo (los enlaces BLE murieron).
  fullRestart,

  /// Cambió algo más (ej. Wi-Fi) y hay enlaces vivos: reiniciar advertising y
  /// discovery sin cortarlos.
  softRestart,
}

/// Acción del control de seguridad periódico.
enum SafetyAction { none, restartDiscovery, restartDiscoveryAndAdvertising }

/// Lógica de decisión de la recuperación de la red Mesh, sin dependencias de
/// Flutter ni de Nearby (igual que `MessageRelay`). Los timers (espera de 3 s,
/// control de 60 s, fallback de 8 s) los maneja el provider.
class MeshRecoveryPolicy {
  /// Espera de estabilidad tras el último evento de medios.
  static const Duration mediaDebounce = Duration(seconds: 3);

  /// Periodo del control de seguridad.
  static const Duration safetyPeriod = Duration(seconds: 60);

  /// Tiempo que espera el nodo de ID menor antes de pedir él la conexión.
  static const Duration initiatorFallbackDelay = Duration(seconds: 8);

  /// Espera tras una desconexión involuntaria antes de reiniciar el discovery
  /// (respaldo cuando una reconexión falla). Agrupa varias caídas seguidas.
  static const Duration rediscoveryDelay = Duration(seconds: 2);

  /// Ventana que se espera, tras una caída involuntaria, a que llegue
  /// `onEndpointLost` antes de reconectar. Si llega, el par se fue (o cambió de
  /// endpointId) y no hay que reconectar. **Valor provisorio, a testear**: en
  /// los logs del 23/10 el `onEndpointLost` llegó 0,05 s después del
  /// `onDisconnected`, en un único caso.
  static const Duration lostGracePeriod = Duration(seconds: 2);

  /// Controles seguidos sin `onEndpointFound` para reiniciar también el advertising.
  static const int checksBeforeAdvertisingRestart = 3;

  MediaState? _media;
  MediaState? _lastApplied;

  /// TEMPORAL: Node IDs que el usuario desconectó a mano. No se aceptan ni se
  /// inician conexiones con ellos hasta pulsar Conectar. Sin vencimiento.
  /// Se reemplazará por un mensaje de despedida (mensajes de control en Envelope).
  final Set<String> _blockedNodes = {};
  bool _bluetoothWasReset = false;
  int _checksWithoutFound = 0;

  /// Último snapshot recibido (null si todavía no hay ninguno).
  MediaState? get media => _media;

  /// Si Nearby puede descubrir (ubicación disponible o estado desconocido).
  bool get canDiscover => _media?.location ?? true;

  /// Registra un snapshot. Si el Bluetooth estuvo apagado, recuerda que los
  /// enlaces BLE murieron hasta que se aplique un reinicio completo.
  void onMediaEvent(MediaState media) {
    _media = media;
    if (!media.bluetooth) _bluetoothWasReset = true;
  }

  /// Decide qué hacer con el último snapshot. Debe llamarse solo cuando el
  /// estado de medios es estable (tras [mediaDebounce]), también al volver a
  /// primer plano. Sin vecinos conectados no hay enlaces que preservar, así que
  /// un cambio de medios se resuelve con un reinicio completo: `stopAllEndpoints`
  /// limpia los endpoints que Nearby pudo haber dejado colgados.
  MediaDecision decide({
    required bool userWantsMesh,
    required bool running,
    int connectedCount = 0,
  }) {
    final media = _media;

    if (!userWantsMesh) {
      _bluetoothWasReset = false;
      _lastApplied = null;
      return MediaDecision.none;
    }
    if (media == null) {
      return running ? MediaDecision.none : MediaDecision.start;
    }

    final previous = _lastApplied;
    _lastApplied = media;

    if (media.noTransport) {
      _bluetoothWasReset = false;
      return MediaDecision.pauseNoMedia;
    }
    if (!media.location) return MediaDecision.pauseDiscovery;

    if (!running) {
      _bluetoothWasReset = false;
      return MediaDecision.start;
    }
    if (_bluetoothWasReset && media.bluetooth) {
      _bluetoothWasReset = false;
      return MediaDecision.fullRestart;
    }
    if (previous == media) return MediaDecision.none;
    return connectedCount == 0
        ? MediaDecision.fullRestart
        : MediaDecision.softRestart;
  }

  /// Un `onEndpointFound` reinicia la cuenta del control de seguridad.
  void onEndpointFound() => _checksWithoutFound = 0;

  /// Control de seguridad: con vecinos conectados no hace nada. Sin vecinos
  /// reinicia el discovery y, tras [checksBeforeAdvertisingRestart] controles
  /// seguidos sin hallazgos, también el advertising.
  SafetyAction onSafetyTick({required int connectedCount}) {
    if (connectedCount > 0) {
      _checksWithoutFound = 0;
      return SafetyAction.none;
    }
    _checksWithoutFound++;
    if (_checksWithoutFound >= checksBeforeAdvertisingRestart) {
      _checksWithoutFound = 0;
      return SafetyAction.restartDiscoveryAndAdvertising;
    }
    return SafetyAction.restartDiscovery;
  }

  /// TEMPORAL: bloquea un nodo desconectado manualmente.
  void blockNode(String nodeId) => _blockedNodes.add(nodeId);

  /// TEMPORAL: si el nodo fue desconectado manualmente.
  bool isBlocked(String nodeId) => _blockedNodes.contains(nodeId);

  /// TEMPORAL: levanta todos los bloqueos (al pulsar Conectar).
  void clearBlocks() => _blockedNodes.clear();

  /// Espera antes de reconectar tras una caída involuntaria: ambos roles
  /// esperan al menos [lostGracePeriod]; el de ID menor mantiene el fallback.
  static Duration reconnectDelay(String myNodeId, String otherNodeId) =>
      isPrimaryInitiator(myNodeId, otherNodeId)
          ? lostGracePeriod
          : initiatorFallbackDelay;

  /// El nodo con ID lexicográficamente mayor pide la conexión de inmediato.
  static bool isPrimaryInitiator(String myNodeId, String otherNodeId) =>
      myNodeId.compareTo(otherNodeId) > 0;
}
