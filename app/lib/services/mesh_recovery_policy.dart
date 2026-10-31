import '../data/models/media_state.dart';

/// Estados del ciclo de vida de la red Mesh.
enum MeshState {
  /// El usuario no pidió conectar (o el inicio falló).
  idle,

  /// Advertising + discovery activos.
  running,

  /// Solo advertising: la ubicación está apagada y el discovery no puede correr.
  /// Los enlaces existentes se preservan.
  runningNoDiscovery,

  /// Sin Bluetooth ni Wi-Fi: Nearby detenido, a la espera de que vuelva un medio.
  pausedNoMedia,
}

/// Acción que el provider debe ejecutar tras una transición de la máquina.
enum MeshAction {
  /// No hace falta hacer nada (incluye repetir un estado en el que ya estamos).
  none,

  /// Iniciar advertising y, si el estado es `running`, también discovery.
  start,

  /// `stopAll`: se pasó a `pausedNoMedia`.
  pause,

  /// Detener solo el discovery (se apagó la ubicación).
  stopDiscovery,

  /// Volver a iniciar el discovery (volvió la ubicación).
  startDiscovery,

  /// `stopAll` + `start`: el Bluetooth cayó estando en marcha, o no hay
  /// enlaces que preservar.
  fullRestart,

  /// Reiniciar advertising (y discovery si corresponde) sin cortar los enlaces vivos.
  softRestart,
}

/// Acción del control de seguridad periódico.
enum SafetyAction { none, restartDiscovery, restartDiscoveryAndAdvertising }

/// Lógica de decisión de la recuperación de la red Mesh, sin dependencias de
/// Flutter ni de Nearby (igual que `MessageRelay`): la máquina de estados del
/// ciclo de vida ([MeshState]), el control de seguridad, el iniciador y el
/// bloqueo manual. Los timers (espera de 3 s, control de 60 s, fallback de 8 s)
/// los maneja el provider, que ejecuta las [MeshAction] que devuelve la máquina.
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

  MeshState _state = MeshState.idle;
  MediaState? _media;
  MediaState? _lastApplied;

  /// Transición observada: el Bluetooth pasó de encendido a no encendido con la
  /// red en marcha. Los enlaces BLE murieron y hace falta un reinicio completo
  /// cuando vuelva a estar encendido.
  bool _bluetoothLostWhileRunning = false;

  /// TEMPORAL: Node IDs que el usuario desconectó a mano. No se aceptan ni se
  /// inician conexiones con ellos hasta pulsar Conectar. Sin vencimiento.
  /// Se reemplazará por un mensaje de despedida (mensajes de control en Envelope).
  final Set<String> _blockedNodes = {};
  int _checksWithoutFound = 0;

  MeshState get state => _state;

  /// Último snapshot recibido (null si todavía no hay ninguno).
  MediaState? get media => _media;

  /// Nearby está en marcha (con o sin discovery).
  bool get isRunning =>
      _state == MeshState.running || _state == MeshState.runningNoDiscovery;

  /// El discovery está activo.
  bool get discoveryActive => _state == MeshState.running;

  /// Registra un snapshot (sin decidir nada: la decisión espera a que los
  /// medios estén estables). Solo memoriza la caída del Bluetooth si ocurre
  /// con la red en marcha y como transición encendido → no encendido.
  void onMediaEvent(MediaState media) {
    final previous = _media;
    _media = media;
    if (isRunning &&
        previous != null &&
        previous.bluetoothOn &&
        !media.bluetoothOn) {
      _bluetoothLostWhileRunning = true;
    }
  }

  /// Evento: el usuario pulsó Conectar.
  MeshAction connect() {
    _resetMemory();
    final media = _media;
    _lastApplied = media;
    if (media != null && media.noTransport) {
      _state = MeshState.pausedNoMedia;
      return MeshAction.none;
    }
    _state = (media == null || media.location)
        ? MeshState.running
        : MeshState.runningNoDiscovery;
    return MeshAction.start;
  }

  /// Evento: el usuario pulsó Desconectar.
  void disconnect() {
    _state = MeshState.idle;
    _resetMemory();
  }

  /// Evento: no se pudo iniciar ni el advertising ni el discovery.
  void onStartFailed() {
    _state = MeshState.idle;
    _resetMemory();
  }

  /// Evento: los medios están estables (tras [mediaDebounce] o al volver a
  /// primer plano). Aplica la tabla de transiciones; repetir el estado en el
  /// que ya se está no genera acciones.
  MeshAction onMediaStable({required int connectedCount}) {
    final media = _media;
    if (_state == MeshState.idle || media == null) return MeshAction.none;
    // Radios en transición: se decide con el próximo snapshot (llega cuando
    // la radio termina de cambiar).
    if (!media.stable) return MeshAction.none;

    final previous = _lastApplied;
    _lastApplied = media;

    switch (_state) {
      case MeshState.idle:
        return MeshAction.none;

      case MeshState.pausedNoMedia:
        if (media.noTransport) return MeshAction.none;
        _bluetoothLostWhileRunning = false;
        _state = media.location
            ? MeshState.running
            : MeshState.runningNoDiscovery;
        return MeshAction.start;

      case MeshState.running:
        if (media.noTransport) return _pause();
        if (!media.location) {
          _state = MeshState.runningNoDiscovery;
          return MeshAction.stopDiscovery;
        }
        return _restartIfNeeded(previous, media, connectedCount);

      case MeshState.runningNoDiscovery:
        if (media.noTransport) return _pause();
        if (media.location) {
          _state = MeshState.running;
          if (_bluetoothLostWhileRunning && media.bluetoothOn) {
            _bluetoothLostWhileRunning = false;
            return MeshAction.fullRestart;
          }
          return MeshAction.startDiscovery;
        }
        return _restartIfNeeded(previous, media, connectedCount);
    }
  }

  MeshAction _pause() {
    _state = MeshState.pausedNoMedia;
    _bluetoothLostWhileRunning = false;
    return MeshAction.pause;
  }

  /// Dentro de un estado en marcha: reinicio completo si cayó el Bluetooth o
  /// si no hay enlaces que preservar; suave si los hay; nada si los medios no
  /// cambiaron desde la última decisión.
  MeshAction _restartIfNeeded(
    MediaState? previous,
    MediaState media,
    int connectedCount,
  ) {
    if (_bluetoothLostWhileRunning && media.bluetoothOn) {
      _bluetoothLostWhileRunning = false;
      return MeshAction.fullRestart;
    }
    if (previous == media) return MeshAction.none;
    return connectedCount == 0
        ? MeshAction.fullRestart
        : MeshAction.softRestart;
  }

  void _resetMemory() {
    _bluetoothLostWhileRunning = false;
    _lastApplied = null;
    _checksWithoutFound = 0;
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
