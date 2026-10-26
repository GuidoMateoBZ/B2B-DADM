import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:nearby_connections/nearby_connections.dart';

import '../data/discovered_endpoint.dart';
import '../data/models/chat_message.dart';
import '../data/models/envelope.dart';
import '../data/models/media_state.dart';
import '../data/nearby_service.dart';
import '../services/local_notification_service.dart';
import '../services/media_state_service.dart';
import '../services/mesh_recovery_policy.dart';
import '../services/message_relay.dart';
import '../services/nearby_permission_handler.dart';
import 'chat_provider.dart';

/// Estados posibles del sistema Nearby Connections.
/// `noMedia` (sin Bluetooth ni Wi-Fi) y `noLocation` (ubicación apagada y sin
/// vecinos) son pausas automáticas: la red se reanuda sola al volver el medio.
enum NearbyState {
  idle,
  searching,
  connecting,
  connected,
  error,
  noMedia,
  noLocation,
}

/// Nivel de alcanzabilidad de un nodo destino.
enum NodeReachability { direct, multihop, unreachable }

/// Provider que gestiona el estado de red de Nearby Connections,
/// descubrimiento continuo, multi-conexión, routing multi-hop (MessageRelay)
/// reenvío de broadcast SOS y recuperación automática ante cambios de medios.
class NearbyProvider extends ChangeNotifier with WidgetsBindingObserver {
  final NearbyService _service = NearbyService();
  final MediaStateService _mediaService;
  final MeshRecoveryPolicy _policy = MeshRecoveryPolicy();

  // ── Estado observable ──

  NearbyState _state = NearbyState.idle;
  NearbyState get state => _state;

  /// Intención del usuario: solo cambia con los botones Conectar / Desconectar.
  bool _userWantsMesh = false;
  bool get isSearching => _userWantsMesh;

  /// Nearby está efectivamente en marcha (advertising + discovery). Lo controla el provider.
  bool _nearbyRunning = false;

  /// Motivo de la pausa automática (`noMedia` / `noLocation`), o null.
  NearbyState? _pausedReason;

  final List<DiscoveredEndpoint> _discoveredEndpoints = [];
  List<DiscoveredEndpoint> get discoveredEndpoints =>
      List.unmodifiable(_discoveredEndpoints);

  /// Mapa de vecinos conectados: endpointId -> nodeId
  final Map<String, String> _connectedEndpoints = {};
  Map<String, String> get connectedEndpoints =>
      Map.unmodifiable(_connectedEndpoints);

  int get connectedCount => _connectedEndpoints.length;
  List<String> get connectedNodeIds => _connectedEndpoints.values.toList();

  final Set<String> _connectingEndpoints = {};

  /// endpointId -> nodeId, cargado en onEndpointFound y onConnectionInitiated.
  final Map<String, String> _endpointNames = {};

  /// Intento de conexión programado (fallback del iniciador o reconexión): un timer por endpoint.
  final Map<String, Timer> _connectTimers = {};

  StreamSubscription<MediaState>? _mediaSub;
  Timer? _mediaDebounce;
  Timer? _safetyTimer;
  Timer? _rediscoveryDebounce;

  /// Serializa las operaciones que tocan Nearby (inicio, pausas, reinicios).
  Future<void> _opChain = Future.value();

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _myNodeId;
  String? get myNodeId => _myNodeId;

  late MessageRelay _relay;
  ChatProvider? _chatProvider;

  // ── Constructor ──

  NearbyProvider({MediaStateService? mediaService})
      : _mediaService = mediaService ?? MediaStateService() {
    _relay = MessageRelay(myNodeId: '');
    _setupCallbacks();
    WidgetsBinding.instance.addObserver(this);
    _mediaSub = _mediaService.stream.listen(
      _onMediaChanged,
      onError: (Object e) =>
          debugPrint('[NearbyProvider] Error en observer de medios: $e'),
    );
  }

  /// Inyecta o actualiza la referencia a ChatProvider.
  void setChatProvider(ChatProvider provider) {
    _chatProvider = provider;
  }

  void _setupCallbacks() {
    _service.onEndpointFound = _onEndpointFound;
    _service.onEndpointLost = _onEndpointLost;
    _service.onConnectionInitiated = _onConnectionInitiated;
    _service.onConnectionResult = _onConnectionResult;
    _service.onDisconnected = _onDisconnected;
    _service.onMessageReceived = _onMessageReceived;
  }

  /// Determina el nivel de alcanzabilidad de un nodo destino.
  NodeReachability getReachability(String targetNodeId) {
    if (_connectedEndpoints.containsValue(targetNodeId)) {
      return NodeReachability.direct;
    }
    if (_connectedEndpoints.isNotEmpty) {
      return NodeReachability.multihop;
    }
    return NodeReachability.unreachable;
  }

  bool isDirectNeighbor(String nodeId) =>
      _connectedEndpoints.containsValue(nodeId);

  // ── Control de Red (Advertising + Discovery) ──

  /// Inicia búsqueda continua (advertising + discovery).
  Future<void> startSearching(String nodeId) async {
    _myNodeId = nodeId;

    // Pedir permisos en runtime
    final permissionResult =
        await PermissionService.requestPermissionsDetailed();
    if (!permissionResult.isGranted) {
      _state = NearbyState.error;
      _errorMessage = permissionResult.missingMessage;
      notifyListeners();
      return;
    }

    _relay = MessageRelay(myNodeId: nodeId);
    _policy.clearBlocks();
    _userWantsMesh = true;
    _errorMessage = null;
    _pausedReason = null;
    _discoveredEndpoints.clear();

    final media = await _mediaService.current();
    if (media != null) _policy.onMediaEvent(media);

    await _enqueue(_applyMediaRules);
  }

  /// Inicia advertising + discovery. Lo usan el botón Conectar y los reinicios
  /// automáticos: no pide permisos ni recrea el MessageRelay.
  Future<void> _startMesh() async {
    final nodeId = _myNodeId;
    if (nodeId == null) return;

    _pausedReason = null;
    _errorMessage = null;
    _state = NearbyState.searching;
    notifyListeners();

    final advResult = await _service.startAdvertising(nodeId);
    final disResult = await _service.startDiscovery(nodeId);

    if (!advResult && !disResult) {
      _userWantsMesh = false;
      _nearbyRunning = false;
      _cancelSafetyTimer();
      _state = NearbyState.error;
      _errorMessage = _service.lastError ??
          'No se pudo conectar a la red. Verificá que el Bluetooth y la ubicación estén encendidos.';
      notifyListeners();
      return;
    }
    if (!advResult || !disResult) {
      debugPrint(
        '[NearbyProvider] Parcialmente iniciado: adv=$advResult, dis=$disResult. Detalle: ${_service.lastError}',
      );
    }

    _nearbyRunning = true;
    _startSafetyTimer();
    _updateCurrentState();
    notifyListeners();
  }

  /// Solicita conexión a un endpoint descubierto.
  ///
  /// Con [rediscoverOnFailure] (reconexiones), si el intento falla se reinicia
  /// el discovery una vez: el endpointId guardado puede ya no ser válido.
  Future<void> connectTo(
    String endpointId, {
    bool rediscoverOnFailure = false,
  }) async {
    if (_myNodeId == null || _connectingEndpoints.contains(endpointId)) return;

    _connectingEndpoints.add(endpointId);
    _state = NearbyState.connecting;
    notifyListeners();

    var result = await _service.requestConnection(_myNodeId!, endpointId);
    final nodeId = _endpointNames[endpointId];
    final nodeAlreadyLinked = nodeId != null &&
        _connectedEndpoints.entries
            .any((e) => e.value == nodeId && e.key != endpointId);
    if (result == ConnectionRequestResult.alreadyConnected &&
        !_connectedEndpoints.containsKey(endpointId) &&
        !nodeAlreadyLinked) {
      // 8003 sobre un endpoint que la app no tiene conectado: Nearby dejó el
      // enlace colgado tras un cambio de medio. Se libera y se reintenta una vez.
      // Si el mismo nodo ya está enlazado con otro endpointId, el 8003 es correcto.
      debugPrint('[NearbyProvider] 8003 con $endpointId sin enlace en la app: liberando y reintentando');
      await _service.disconnectFromEndpoint(endpointId);
      await Future<void>.delayed(NearbyService.restartPause);
      result = await _service.requestConnection(_myNodeId!, endpointId);
    }
    if (result != ConnectionRequestResult.requested) {
      debugPrint('[NearbyProvider] requestConnection a $endpointId: $result '
          '(código ${_service.lastErrorCode}, ${_service.lastError})');
      _connectingEndpoints.remove(endpointId);
      if (rediscoverOnFailure && result == ConnectionRequestResult.failed) {
        _scheduleRediscovery();
      }
      _updateCurrentState();
      notifyListeners();
    }
  }

  /// Detiene todas las conexiones, advertising y discovery.
  Future<void> stopSearching() => _enqueue(() async {
        _userWantsMesh = false;
        _nearbyRunning = false;
        _pausedReason = null;
        _mediaDebounce?.cancel();
        _cancelSafetyTimer();
        await _safeStopAll();
        _clearNeighbors();
        _relay.clearSeenMessages();
        _state = NearbyState.idle;
        _errorMessage = null;
        notifyListeners();
      });

  /// Desconecta de un endpoint específico.
  /// TEMPORAL: además bloquea al nodo para que ninguno de los dos lo reconecte.
  Future<void> disconnectEndpoint(String endpointId) async {
    final nodeId = _connectedEndpoints[endpointId];
    if (nodeId != null) _policy.blockNode(nodeId);
    await _service.disconnectFromEndpoint(endpointId);
    _onDisconnected(endpointId, manual: true);
  }

  // ── Envío de Mensajes ──

  /// Envía un mensaje 1-a-1 a un nodo destino específico.
  /// Si es vecino directo, se envía a su endpoint; si no, se propaga por flooding.
  Future<void> sendChatMessage(String targetNodeId, String text) async {
    if (_myNodeId == null || text.trim().isEmpty) return;

    final envelope = Envelope.create(
      fromNodeId: _myNodeId!,
      toNodeId: targetNodeId,
      text: text.trim(),
      ttl: Envelope.defaultTtl,
    );

    // 1. Guardar localmente
    final chatMsg = ChatMessage.fromEnvelope(envelope, isMine: true);
    await _chatProvider?.addMessage(chatMsg);

    // 2. Obtener destinos del relay
    final targets = _relay.getTargetEndpoints(envelope);
    if (targets.isNotEmpty) {
      debugPrint(
        '[NearbyProvider] Enviando mensaje ${envelope.messageId} a endpoints: $targets',
      );
      await _service.sendToEndpoints(targets, envelope.encode());
    } else {
      debugPrint(
        '[NearbyProvider] No hay vecinos conectados para rutear mensaje a $targetNodeId',
      );
    }
  }

  /// Envía un broadcast SOS a todos los vecinos conectados para propagación epidémica.
  Future<void> sendBroadcast(String text) async {
    if (_myNodeId == null || text.trim().isEmpty) return;

    final envelope = Envelope.create(
      fromNodeId: _myNodeId!,
      toNodeId: Envelope.broadcastAddress,
      text: text.trim(),
      ttl: Envelope.defaultTtl,
    );

    // 1. Guardar localmente
    final chatMsg = ChatMessage.fromEnvelope(envelope, isMine: true);
    await _chatProvider?.addMessage(chatMsg);

    // 2. Enviar a todos los vecinos conectados
    final targets = _relay.getTargetEndpoints(envelope);
    if (targets.isNotEmpty) {
      debugPrint(
        '[NearbyProvider] Enviando SOS ${envelope.messageId} a endpoints: $targets',
      );
      await _service.sendToEndpoints(targets, envelope.encode());
    }
  }

  // ── Callbacks de NearbyService ──

  void _onEndpointFound(String endpointId, String userName) {
    debugPrint('[NearbyProvider] onEndpointFound $endpointId ($userName)');
    _policy.onEndpointFound();
    _endpointNames[endpointId] = userName;
    _rememberDiscovered(endpointId, userName);
    _autoConnect(endpointId, userName, afterDisconnect: false);
  }

  /// Registra al par como visto y no conectado (lo usan el descubrimiento y las caídas).
  void _rememberDiscovered(String endpointId, String nodeId) {
    final alreadyExists =
        _discoveredEndpoints.any((e) => e.endpointId == endpointId);
    if (!alreadyExists && !_connectedEndpoints.containsKey(endpointId)) {
      _discoveredEndpoints.add(
        DiscoveredEndpoint(endpointId: endpointId, userName: nodeId),
      );
      notifyListeners();
    }
  }

  /// Auto-conexión: para evitar colisiones cruzadas cuando ambos se descubren a la vez,
  /// el nodo con ID lexicográficamente mayor inicia la solicitud. Si el de ID menor
  /// ve al mayor y no recibe una conexión entrante en 8 s, la pide él (un solo intento).
  /// Tras una caída ([afterDisconnect]) ambos esperan la ventana de `onEndpointLost`
  /// antes de reconectar.
  void _autoConnect(
    String endpointId,
    String nodeId, {
    required bool afterDisconnect,
  }) {
    final myNodeId = _myNodeId;
    if (myNodeId == null ||
        _connectedEndpoints.containsKey(endpointId) ||
        _connectingEndpoints.contains(endpointId)) {
      return;
    }
    if (_policy.isBlocked(nodeId)) {
      debugPrint('[NearbyProvider] $nodeId bloqueado (desconexión manual): no se conecta');
      return;
    }
    if (afterDisconnect) {
      final delay = MeshRecoveryPolicy.reconnectDelay(myNodeId, nodeId);
      debugPrint('[NearbyProvider] Reconexión a $endpointId ($nodeId) programada en ${delay.inSeconds} s');
      _scheduleConnectAttempt(endpointId, delay, afterDisconnect: true);
    } else if (MeshRecoveryPolicy.isPrimaryInitiator(myNodeId, nodeId)) {
      connectTo(endpointId);
    } else {
      _scheduleConnectAttempt(
        endpointId,
        MeshRecoveryPolicy.initiatorFallbackDelay,
      );
    }
  }

  /// Un único intento de conexión diferido. Al vencer solo conecta si el par
  /// sigue visible: un `onEndpointLost` o una conexión entrante lo cancelan.
  void _scheduleConnectAttempt(
    String endpointId,
    Duration delay, {
    bool afterDisconnect = false,
  }) {
    _connectTimers.remove(endpointId)?.cancel();
    _connectTimers[endpointId] = Timer(delay, () {
      _connectTimers.remove(endpointId);
      final nodeId = _endpointNames[endpointId];
      final stillVisible =
          _discoveredEndpoints.any((e) => e.endpointId == endpointId);
      if (!stillVisible) {
        debugPrint('[NearbyProvider] Conexión a $endpointId cancelada: ya no está visible');
      } else if (_nearbyRunning &&
          !_connectedEndpoints.containsKey(endpointId) &&
          !_connectingEndpoints.contains(endpointId) &&
          !(nodeId != null && _policy.isBlocked(nodeId))) {
        debugPrint('[NearbyProvider] Conectando a $endpointId (${afterDisconnect ? 'reconexión' : 'fallback del iniciador'})');
        connectTo(endpointId, rediscoverOnFailure: afterDisconnect);
      }
    });
  }

  void _onEndpointLost(String endpointId) {
    debugPrint('[NearbyProvider] onEndpointLost $endpointId');
    if (_connectTimers.remove(endpointId) != null) {
      debugPrint('[NearbyProvider] Reconexión cancelada: onEndpointLost');
    }

    _discoveredEndpoints.removeWhere((e) => e.endpointId == endpointId);
    if (!_connectedEndpoints.containsKey(endpointId)) {
      _endpointNames.remove(endpointId);
    }
    notifyListeners();
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    _connectTimers.remove(endpointId)?.cancel();
    if (info.endpointName.isNotEmpty && info.endpointName != '-1') {
      _endpointNames[endpointId] = info.endpointName;
    }
    final nodeId = _endpointNames[endpointId];
    if (nodeId != null && _policy.isBlocked(nodeId)) {
      debugPrint('[NearbyProvider] Conexión rechazada: nodo bloqueado ($nodeId)');
      unawaited(_service.rejectConnection(endpointId));
      return;
    }
    // Aceptar conexiones entrantes automáticamente
    _service.acceptConnection(endpointId);
  }

  void _onConnectionResult(String endpointId, Status status) {
    debugPrint('[NearbyProvider] onConnectionResult $endpointId: $status');
    _connectingEndpoints.remove(endpointId);
    _connectTimers.remove(endpointId)?.cancel();

    if (status == Status.CONNECTED) {
      final discovered = _discoveredEndpoints
          .where((e) => e.endpointId == endpointId)
          .firstOrNull;
      final nodeName =
          _endpointNames[endpointId] ?? discovered?.userName ?? endpointId;

      // Deduplicación por Node ID: se conserva la conexión nueva y se descarta
      // la vieja (el par reinició y anuncia con otro endpointId).
      final stale = _connectedEndpoints.entries
          .where((e) => e.value == nodeName && e.key != endpointId)
          .map((e) => e.key)
          .toList();
      for (final old in stale) {
        _connectedEndpoints.remove(old);
        _relay.removeNeighbor(old);
        _endpointNames.remove(old);
        unawaited(_service.disconnectFromEndpoint(old));
      }

      _connectedEndpoints[endpointId] = nodeName;
      _relay.addNeighbor(endpointId, nodeName);
      _discoveredEndpoints.removeWhere((e) => e.endpointId == endpointId);

      _updateCurrentState();
      _errorMessage = null;
    } else {
      _endpointNames.remove(endpointId);
      _updateCurrentState();
    }
    notifyListeners();
  }

  void _onDisconnected(String endpointId, {bool manual = false}) {
    debugPrint('[NearbyProvider] onDisconnected $endpointId${manual ? ' (manual)' : ''}');
    final nodeId = _connectedEndpoints[endpointId];
    _connectedEndpoints.remove(endpointId);
    _relay.removeNeighbor(endpointId);
    _connectingEndpoints.remove(endpointId);

    if (nodeId != null && !manual && _nearbyRunning) {
      // Caída involuntaria: el par sigue anunciándose, así que Nearby no vuelve a
      // emitir onEndpointFound. Mientras no llegue onEndpointLost su endpointId
      // sigue vigente: se lo vuelve a registrar y se programa un único intento.
      _rememberDiscovered(endpointId, nodeId);
      _autoConnect(endpointId, nodeId, afterDisconnect: true);
    } else {
      _endpointNames.remove(endpointId);
    }

    _updateCurrentState();
    notifyListeners();
  }

  void _scheduleRediscovery() {
    _rediscoveryDebounce?.cancel();
    _rediscoveryDebounce = Timer(
      MeshRecoveryPolicy.rediscoveryDelay,
      () => _enqueue(_rediscover),
    );
  }

  /// Reinicia solo el discovery (los enlaces vivos no se tocan) para que el
  /// par desconectado vuelva a aparecer y aplique la lógica del iniciador.
  Future<void> _rediscover() async {
    final nodeId = _myNodeId;
    if (!_nearbyRunning || nodeId == null || !_policy.canDiscover) return;
    debugPrint('[NearbyProvider] Desconexión involuntaria: reiniciando discovery');
    await _service.restartDiscovery(nodeId);
  }

  void _onMessageReceived(String endpointId, String rawMessage) {
    try {
      final envelope = Envelope.decode(rawMessage);
      final result = _relay.processIncoming(endpointId, envelope);

      if (result.action == RelayAction.deliver) {
        final chatMsg = ChatMessage.fromEnvelope(envelope, isMine: false);
        _chatProvider?.addMessage(chatMsg);

        if (envelope.isBroadcast) {
          unawaited(
            localNotificationService.showSosAlert(
              envelope.fromNodeId,
              envelope.text,
            ),
          );
        } else {
          unawaited(
            localNotificationService.showIncomingMessage(envelope.fromNodeId),
          );
        }
      }

      // Reenviar si corresponde (multi-hop o broadcast)
      if (result.forwardTo.isNotEmpty) {
        debugPrint(
          '[NearbyProvider] Reenviando mensaje ${result.envelope.messageId} (TTL ${result.envelope.ttl}) a: ${result.forwardTo}',
        );
        _service.sendToEndpoints(result.forwardTo, result.envelope.encode());
      }
    } catch (e, stack) {
      debugPrint(
        '[NearbyProvider] Error procesando mensaje de $endpointId: $e\n$stack',
      );
    }
  }

  void _updateCurrentState() {
    if (!_userWantsMesh) {
      _state = NearbyState.idle;
    } else if (_connectedEndpoints.isNotEmpty) {
      _state = NearbyState.connected;
    } else if (_pausedReason != null) {
      _state = _pausedReason!;
    } else if (_connectingEndpoints.isNotEmpty) {
      _state = NearbyState.connecting;
    } else {
      _state = NearbyState.searching;
    }
  }

  // ── Recuperación automática (medios + control de seguridad) ──

  Future<void> _enqueue(Future<void> Function() op) {
    _opChain = _opChain.then((_) async {
      try {
        await op();
      } catch (e, stack) {
        debugPrint('[NearbyProvider] Error en operación de red: $e\n$stack');
      }
    });
    return _opChain;
  }

  void _onMediaChanged(MediaState media) {
    debugPrint('[NearbyProvider] Medios: $media');
    _policy.onMediaEvent(media);
    _mediaDebounce?.cancel();
    _mediaDebounce = Timer(
      MeshRecoveryPolicy.mediaDebounce,
      () => _enqueue(_applyMediaRules),
    );
  }

  Future<void> _applyMediaRules() async {
    final decision = _policy.decide(
      userWantsMesh: _userWantsMesh,
      running: _nearbyRunning,
      connectedCount: connectedCount,
    );
    if (decision != MediaDecision.none) {
      debugPrint('[NearbyProvider] Medios -> $decision');
    }

    switch (decision) {
      case MediaDecision.none:
        break;
      case MediaDecision.pauseNoMedia:
        await _pauseMesh(NearbyState.noMedia);
      case MediaDecision.pauseDiscovery:
        // Los enlaces y el advertising no dependen de la ubicación: se preservan.
        _pausedReason = NearbyState.noLocation;
        if (_nearbyRunning) await _service.stopDiscovery();
        _discoveredEndpoints.clear();
        _updateCurrentState();
        notifyListeners();
      case MediaDecision.start:
        await _startMesh();
      case MediaDecision.fullRestart:
        // Los enlaces BLE ya murieron: se evitan las conexiones fantasma.
        await _safeStopAll();
        _clearNeighbors();
        await _startMesh();
      case MediaDecision.softRestart:
        // Sin stopAllEndpoints: se preservan los enlaces que sobrevivieron.
        _pausedReason = null;
        _discoveredEndpoints.clear();
        await _restartAdvertisingAndDiscovery();
        _updateCurrentState();
        notifyListeners();
    }
  }

  Future<void> _pauseMesh(NearbyState reason) async {
    _cancelSafetyTimer();
    await _safeStopAll();
    _clearNeighbors();
    _nearbyRunning = false;
    _pausedReason = reason;
    _updateCurrentState();
    notifyListeners();
  }

  Future<void> _restartAdvertisingAndDiscovery() async {
    final nodeId = _myNodeId;
    if (nodeId == null) return;
    await _service.restartAdvertising(nodeId);
    await _service.restartDiscovery(nodeId);
  }

  void _startSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = Timer.periodic(
      MeshRecoveryPolicy.safetyPeriod,
      (_) => _enqueue(_safetyCheck),
    );
  }

  void _cancelSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  /// Control de seguridad: cubre al dispositivo que no tuvo el cambio de medio.
  Future<void> _safetyCheck() async {
    final nodeId = _myNodeId;
    if (!_nearbyRunning || nodeId == null || !_policy.canDiscover) return;

    final action = _policy.onSafetyTick(connectedCount: connectedCount);
    if (action == SafetyAction.none) return;

    debugPrint('[NearbyProvider] Control de seguridad -> $action');
    // Tras reiniciar el discovery no llegan onEndpointLost: se descartan las
    // entradas viejas y las conexiones trabadas.
    _discoveredEndpoints.clear();
    _connectingEndpoints.clear();
    _updateCurrentState();
    notifyListeners();

    if (action == SafetyAction.restartDiscoveryAndAdvertising) {
      await _service.restartAdvertising(nodeId);
    }
    await _service.restartDiscovery(nodeId);
  }

  Future<void> _safeStopAll() async {
    try {
      await _service.stopAll();
    } catch (e) {
      debugPrint('[NearbyProvider] stopAll con errores: $e');
    }
  }

  void _clearNeighbors() {
    for (final endpointId in _connectedEndpoints.keys) {
      _relay.removeNeighbor(endpointId);
    }
    _connectedEndpoints.clear();
    _discoveredEndpoints.clear();
    _connectingEndpoints.clear();
    _endpointNames.clear();
    for (final timer in _connectTimers.values) {
      timer.cancel();
    }
    _connectTimers.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_userWantsMesh) return;
    // Pasa por la misma espera de estabilidad que los eventos: al cambiar el
    // modo avión desde el panel rápido, la app vuelve a `resumed` en plena
    // transición de los medios y aplicar las reglas ahí reiniciaría demasiado pronto.
    unawaited(_mediaService.current().then((media) {
      if (media != null) _onMediaChanged(media);
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mediaSub?.cancel();
    _mediaDebounce?.cancel();
    _rediscoveryDebounce?.cancel();
    _cancelSafetyTimer();
    for (final timer in _connectTimers.values) {
      timer.cancel();
    }
    unawaited(_safeStopAll());
    super.dispose();
  }
}
