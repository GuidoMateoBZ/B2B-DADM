import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/discovered_endpoint.dart';
import '../data/message_storage.dart';
import '../data/models/chat_message.dart';
import '../data/models/envelope.dart';
import '../data/models/media_state.dart';
import '../data/nearby_service.dart';
import '../data/node_id_storage.dart';
import '../services/background_mesh_service.dart';
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
  final bool _isBackgroundController;
  late final BackgroundMeshService _backgroundService =
      BackgroundMeshService.instance;

  // ── Estado observable ──

  NearbyState _state = NearbyState.idle;
  NearbyState get state => _state;

  /// El usuario pidió conectar: la máquina de estados no está en `idle`.
  /// El ciclo de vida de la red (en marcha, sin discovery, pausada) lo lleva
  /// `MeshRecoveryPolicy`.
  bool _remoteIsSearching = false;
  bool get isSearching => _isBackgroundController
      ? _policy.state != MeshState.idle
      : _remoteIsSearching;

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
  StreamSubscription<Map<String, dynamic>?>? _snapshotSub;
  StreamSubscription<Map<String, dynamic>?>? _messageSub;
  StreamSubscription<void>? _navigationSub;
  Timer? _mediaDebounce;
  Timer? _safetyTimer;
  Timer? _rediscoveryDebounce;
  final Set<String> _pendingStopEndpoints = {};
  Completer<void>? _stopDisconnectionsCompleter;
  bool _isStoppingMesh = false;

  /// Serializa las operaciones que tocan Nearby (inicio, pausas, reinicios).
  Future<void> _opChain = Future.value();
  static const Duration _stopDisconnectionTimeout = Duration(seconds: 5);
  static const Duration _stopDrainPeriod = Duration(seconds: 2);

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _myNodeId;
  String? get myNodeId => _myNodeId;

  late MessageRelay _relay;
  ChatProvider? _chatProvider;
  void Function(String, [Map<String, dynamic>?])? _serviceEmitter;
  bool _uiForeground = false;
  String? _visibleChatNodeId;
  bool _broadcastVisible = false;

  // ── Constructor ──

  NearbyProvider({MediaStateService? mediaService})
    : _isBackgroundController = false,
      _mediaService = mediaService ?? MediaStateService() {
    _relay = MessageRelay(myNodeId: '');
    WidgetsBinding.instance.addObserver(this);
    _snapshotSub = _backgroundService
        .on('mesh_snapshot')
        .listen(_applyServiceSnapshot);
    _messageSub = _backgroundService.on('messages_changed').listen((_) {
      unawaited(_chatProvider?.refreshFromStorage());
    });
    _mediaSub = _mediaService.stream.listen(
      (media) => _backgroundService.invoke('media_state', media.toMap()),
      onError: (Object e) =>
          debugPrint('[NearbyProvider] Error en observer de medios: $e'),
    );
    _navigationSub = appNavigationObserver.changes.listen((_) {
      _publishUiPresence();
    });
    _publishUiPresence();
    unawaited(_requestExistingServiceState());
  }

  NearbyProvider.backgroundController()
    : _isBackgroundController = true,
      _mediaService = MediaStateService() {
    _relay = MessageRelay(myNodeId: '');
    _setupCallbacks();
  }

  Future<void> initializeBackgroundController() async {
    await localNotificationService.initialize(background: true);
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_activeSessionKey) != true) return;

    final nodeId = await NodeIdStorage().getId();
    final action = _policy.connect();
    _myNodeId = nodeId;
    _relay = MessageRelay(myNodeId: nodeId);
    await _execute(action);
  }

  Future<void> _requestExistingServiceState() async {
    if (await _backgroundService.isRunning()) {
      _backgroundService.invoke('request_snapshot');
    }
  }

  static const String _activeSessionKey = 'mesh_session_active';

  void setServiceEmitter(void Function(String, [Map<String, dynamic>?]) emit) {
    _serviceEmitter = emit;
  }

  void _log(String message) {
    debugPrint(
      '[NearbyProvider][${_isBackgroundController ? 'background' : 'ui'}] '
      '$message',
    );
  }

  void emitServiceSnapshot() {
    _serviceEmitter?.call('mesh_snapshot', {
      'state': _state.name,
      'searching': isSearching,
      'myNodeId': _myNodeId,
      'errorMessage': _errorMessage,
      'discovered': [
        for (final endpoint in _discoveredEndpoints)
          {'endpointId': endpoint.endpointId, 'userName': endpoint.userName},
      ],
      'connected': Map<String, String>.from(_connectedEndpoints),
      'connecting': _connectingEndpoints.toList(),
    });
  }

  void _applyServiceSnapshot(Map<String, dynamic>? snapshot) {
    if (_isBackgroundController || snapshot == null) return;
    final previousState = _state;
    final stateName = snapshot['state'] as String?;
    if (stateName != null) {
      _state = NearbyState.values.firstWhere(
        (state) => state.name == stateName,
        orElse: () => NearbyState.error,
      );
    }
    _remoteIsSearching = snapshot['searching'] as bool? ?? false;
    _myNodeId = snapshot['myNodeId'] as String?;
    _errorMessage = snapshot['errorMessage'] as String?;
    _discoveredEndpoints
      ..clear()
      ..addAll(
        (snapshot['discovered'] as List<dynamic>? ?? []).map((entry) {
          final map = entry as Map<dynamic, dynamic>;
          return DiscoveredEndpoint(
            endpointId: map['endpointId'] as String,
            userName: map['userName'] as String,
          );
        }),
      );
    _connectedEndpoints
      ..clear()
      ..addAll(
        (snapshot['connected'] as Map<dynamic, dynamic>? ?? {}).map(
          (key, value) => MapEntry(key as String, value as String),
        ),
      );
    _connectingEndpoints
      ..clear()
      ..addAll((snapshot['connecting'] as List<dynamic>? ?? []).cast<String>());
    if (_state != previousState) {
      _log(
        'Estado actualizado desde el servicio: $previousState -> $_state; '
        'descubiertos=${_discoveredEndpoints.length}, '
        'conectados=${_connectedEndpoints.length}, '
        'conectando=${_connectingEndpoints.length}',
      );
    }
    notifyListeners();
  }

  void _publishUiPresence() {
    if (_isBackgroundController) return;
    _backgroundService.invoke('ui_state', _uiPresence());
  }

  Map<String, dynamic> _uiPresence() {
    final observer = appNavigationObserver;
    return {
      'foreground': observer.isForeground,
      'chatNodeId': observer.visibleChatNodeId,
      'broadcastVisible': observer.isBroadcastVisible,
    };
  }

  void updateUiPresence(Map<String, dynamic> presence) {
    if (!_isBackgroundController) return;
    _uiForeground = presence['foreground'] as bool? ?? false;
    _visibleChatNodeId = presence['chatNodeId'] as String?;
    _broadcastVisible = presence['broadcastVisible'] as bool? ?? false;
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
    _log('Solicitud de conexión a la mesh');
    final permissionResult =
        await PermissionService.requestPermissionsDetailed();
    if (!permissionResult.isGranted) {
      _log('Conexión cancelada: ${permissionResult.missingMessage}');
      _state = NearbyState.error;
      _errorMessage = permissionResult.missingMessage;
      notifyListeners();
      return;
    }

    final media = await _mediaService.current();
    final ready = await _backgroundService.ensureRunning();
    if (!ready) {
      _log('Conexión cancelada: servicio de fondo no confirmó inicio');
      _state = NearbyState.error;
      _errorMessage = 'No se pudo iniciar el servicio de red en segundo plano.';
      notifyListeners();
      return;
    }

    _myNodeId = nodeId;
    _backgroundService.invoke('start_search', {
      'nodeId': nodeId,
      'media': media?.toMap(),
      'uiState': _uiPresence(),
    });
    _log(
      'Comando start_search enviado; medios=${media == null ? 'no disponibles' : 'capturados'}',
    );
  }

  Future<void> startSearchingInBackground(
    String nodeId,
    Map<dynamic, dynamic>? initialMedia, [
    Map<dynamic, dynamic>? initialUiState,
  ]) async {
    if (!_isBackgroundController) return;
    _log('Procesando start_search');
    if (initialUiState != null) {
      updateUiPresence(Map<String, dynamic>.from(initialUiState));
    }
    if (_myNodeId == nodeId && _policy.state != MeshState.idle) {
      _log('start_search ignorado: sesión ya activa');
      emitServiceSnapshot();
      return;
    }
    _isStoppingMesh = false;
    _relay = MessageRelay(myNodeId: nodeId);
    _policy.clearBlocks();
    _errorMessage = null;
    _discoveredEndpoints.clear();
    _myNodeId = nodeId;
    await (await SharedPreferences.getInstance()).setBool(
      _activeSessionKey,
      true,
    );
    if (initialMedia != null) {
      _policy.onMediaEvent(MediaState.fromMap(initialMedia));
    }
    await _enqueue(() => _execute(_policy.connect()));
  }

  /// Inicia advertising y, si la máquina está en `running`, también discovery.
  /// Lo usan el botón Conectar y los reinicios automáticos: no pide permisos
  /// ni recrea el MessageRelay.
  Future<void> _startMesh() async {
    final nodeId = _myNodeId;
    if (nodeId == null) return;

    _log('Iniciando advertising y discovery=${_policy.discoveryActive}');
    _errorMessage = null;
    _updateCurrentState();
    notifyListeners();

    final advResult = await _service.startAdvertising(nodeId);
    final disResult = _policy.discoveryActive
        ? await _service.startDiscovery(nodeId)
        : true;

    if (!advResult && !disResult) {
      _policy.onStartFailed();
      _cancelSafetyTimer();
      _state = NearbyState.error;
      _errorMessage = _service.lastError ?? 'No se pudo conectar a la red. Verificá que el Bluetooth y la ubicación estén encendidos.';
      _log(
        'Inicio fallido: adv=$advResult, discovery=$disResult; $_errorMessage',
      );
      notifyListeners();
      return;
    }
    if (!advResult || !disResult) {
      debugPrint(
        '[NearbyProvider] Parcialmente iniciado: adv=$advResult, dis=$disResult. Detalle: ${_service.lastError}',
      );
    }

    _startSafetyTimer();
    _updateCurrentState();
    _log(
      'Inicio finalizado: adv=$advResult, discovery=$disResult, estado=$_state'
      '${_service.lastError == null ? '' : ', detalle=${_service.lastError}'}',
    );
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

    _log('Solicitando conexión con endpoint=$endpointId');
    _connectingEndpoints.add(endpointId);
    _state = NearbyState.connecting;
    notifyListeners();

    var result = await _service.requestConnection(_myNodeId!, endpointId);
    _log('Resultado de solicitud a $endpointId: $result');
    final nodeId = _endpointNames[endpointId];
    final nodeAlreadyLinked =
        nodeId != null &&
        _connectedEndpoints.entries.any(
          (e) => e.value == nodeId && e.key != endpointId,
        );
    if (result == ConnectionRequestResult.alreadyConnected &&
        !_connectedEndpoints.containsKey(endpointId) &&
        !nodeAlreadyLinked) {
      // 8003 sobre un endpoint que la app no tiene conectado: Nearby dejó el
      // enlace colgado tras un cambio de medio. Se libera y se reintenta una vez.
      // Si el mismo nodo ya está enlazado con otro endpointId, el 8003 es correcto.
      debugPrint(
        '[NearbyProvider] 8003 con $endpointId sin enlace en la app: liberando y reintentando',
      );
      await _service.disconnectFromEndpoint(endpointId);
      await Future<void>.delayed(NearbyService.restartPause);
      result = await _service.requestConnection(_myNodeId!, endpointId);
      _log('Resultado del reintento a $endpointId: $result');
    }
    if (result != ConnectionRequestResult.requested) {
      debugPrint(
        '[NearbyProvider] requestConnection a $endpointId: $result '
        '(código ${_service.lastErrorCode}, ${_service.lastError})',
      );
      _connectingEndpoints.remove(endpointId);
      if (rediscoverOnFailure && result == ConnectionRequestResult.failed) {
        _scheduleRediscovery();
      }
      _updateCurrentState();
      notifyListeners();
    }
  }

  /// Detiene todas las conexiones, advertising y discovery.
  Future<void> stopSearching() async {
    if (!_isBackgroundController) {
      _backgroundService.invoke('stop_search');
      _remoteIsSearching = false;
      _state = NearbyState.idle;
      _connectedEndpoints.clear();
      _discoveredEndpoints.clear();
      _connectingEndpoints.clear();
      _errorMessage = null;
      notifyListeners();
      return;
    }
    await stopSearchingInBackground();
  }

  Future<bool> stopSearchingInBackground() async {
    if (!_isBackgroundController) return false;
    _isStoppingMesh = true;
    await (await SharedPreferences.getInstance()).setBool(
      _activeSessionKey,
      false,
    );
    _pendingStopEndpoints
      ..clear()
      ..addAll(_connectedEndpoints.keys);
    _stopDisconnectionsCompleter = _pendingStopEndpoints.isEmpty
        ? null
        : Completer<void>();
    var stopped = false;
    await _enqueue(() async {
      _policy.disconnect();
      _mediaDebounce?.cancel();
      _cancelSafetyTimer();
      stopped = await _safeStopAll();
      if (stopped && _stopDisconnectionsCompleter != null) {
        try {
          await _stopDisconnectionsCompleter!.future.timeout(
            _stopDisconnectionTimeout,
          );
        } on TimeoutException {
          stopped = false;
          _log(
            'No llegaron las desconexiones de '
            '${_pendingStopEndpoints.join(', ')} en '
            '${_stopDisconnectionTimeout.inSeconds} s',
          );
        }
      }
      if (stopped) {
        _log(
          'Esperando ${_stopDrainPeriod.inMilliseconds} ms para callbacks nativos tardíos',
        );
        await Future<void>.delayed(_stopDrainPeriod);
      }
      _pendingStopEndpoints.clear();
      _stopDisconnectionsCompleter = null;
      _clearNeighbors();
      _relay.clearSeenMessages();
      _errorMessage = stopped
          ? null
          : 'No se pudo confirmar el cierre de la red Nearby.';
      _state = stopped ? NearbyState.idle : NearbyState.error;
      notifyListeners();
    });
    return stopped;
  }

  /// Desconecta de un endpoint específico.
  /// TEMPORAL: además bloquea al nodo para que ninguno de los dos lo reconecte.
  Future<void> disconnectEndpoint(String endpointId) async {
    if (!_isBackgroundController) {
      _backgroundService.invoke('disconnect_endpoint', {
        'endpointId': endpointId,
      });
      return;
    }
    await disconnectEndpointInBackground(endpointId);
  }

  Future<void> disconnectEndpointInBackground(String endpointId) async {
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

    await _sendEnvelope(envelope);
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

    await _sendEnvelope(envelope);
  }

  Future<void> _sendEnvelope(Envelope envelope) async {
    if (!_isBackgroundController) {
      final chatMsg = ChatMessage.fromEnvelope(envelope, isMine: true);
      await _chatProvider?.addMessage(chatMsg);
      _backgroundService.invoke('send_envelope', {
        'envelope': envelope.encode(),
      });
      return;
    }
    await sendEnvelopeInBackground(envelope.encode());
  }

  Future<void> sendEnvelopeInBackground(String encodedEnvelope) async {
    if (!_isBackgroundController) return;
    final envelope = Envelope.decode(encodedEnvelope);
    final targets = _relay.getTargetEndpoints(envelope);
    if (targets.isNotEmpty) {
      debugPrint(
        '[NearbyProvider] Enviando ${envelope.messageId} a endpoints: $targets',
      );
      await _service.sendToEndpoints(targets, envelope.encode());
    } else {
      debugPrint(
        '[NearbyProvider] No hay vecinos conectados para rutear ${envelope.messageId}',
      );
    }
  }

  // ── Callbacks de NearbyService ──

  void _onEndpointFound(String endpointId, String userName) {
    if (_isStoppingMesh) {
      _log('Ignorando endpoint=$endpointId: la red está cerrándose');
      return;
    }
    debugPrint('[NearbyProvider] onEndpointFound $endpointId ($userName)');
    _policy.onEndpointFound();
    _endpointNames[endpointId] = userName;
    _rememberDiscovered(endpointId, userName);
    _autoConnect(endpointId, userName, afterDisconnect: false);
  }

  /// Registra al par como visto y no conectado (lo usan el descubrimiento y las caídas).
  void _rememberDiscovered(String endpointId, String nodeId) {
    final alreadyExists = _discoveredEndpoints.any(
      (e) => e.endpointId == endpointId,
    );
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
      debugPrint(
        '[NearbyProvider] $nodeId bloqueado (desconexión manual): no se conecta',
      );
      return;
    }
    if (afterDisconnect) {
      final delay = MeshRecoveryPolicy.reconnectDelay(myNodeId, nodeId);
      debugPrint(
        '[NearbyProvider] Reconexión a $endpointId ($nodeId) programada en ${delay.inSeconds} s',
      );
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
      final stillVisible = _discoveredEndpoints.any(
        (e) => e.endpointId == endpointId,
      );
      if (!stillVisible) {
        debugPrint(
          '[NearbyProvider] Conexión a $endpointId cancelada: ya no está visible',
        );
      } else if (_policy.isRunning &&
          !_connectedEndpoints.containsKey(endpointId) &&
          !_connectingEndpoints.contains(endpointId) &&
          !(nodeId != null && _policy.isBlocked(nodeId))) {
        debugPrint(
          '[NearbyProvider] Conectando a $endpointId (${afterDisconnect ? 'reconexión' : 'fallback del iniciador'})',
        );
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
    _log(
      'Handshake iniciado con endpoint=$endpointId, '
      'nombreRemoto=${info.endpointName.isEmpty ? 'no informado' : info.endpointName}',
    );
    if (_isStoppingMesh) {
      _log('Rechazando handshake de $endpointId: la red está cerrándose');
      unawaited(_service.rejectConnection(endpointId));
      return;
    }
    if (info.endpointName.isNotEmpty && info.endpointName != '-1') {
      _endpointNames[endpointId] = info.endpointName;
    }
    final nodeId = _endpointNames[endpointId];
    if (nodeId != null && _policy.isBlocked(nodeId)) {
      debugPrint(
        '[NearbyProvider] Conexión rechazada: nodo bloqueado ($nodeId)',
      );
      unawaited(_service.rejectConnection(endpointId));
      return;
    }
    // Aceptar conexiones entrantes automáticamente
    unawaited(_acceptConnection(endpointId));
  }

  Future<void> _acceptConnection(String endpointId) async {
    final accepted = await _service.acceptConnection(endpointId);
    _log(
      'Aceptación enviada para endpoint=$endpointId: accepted=$accepted'
      '${_service.lastError == null ? '' : ', detalle=${_service.lastError}'}',
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    debugPrint('[NearbyProvider] onConnectionResult $endpointId: $status');
    _connectingEndpoints.remove(endpointId);
    _connectTimers.remove(endpointId)?.cancel();

    if (_isStoppingMesh) {
      _log(
        'Resultado de conexión ignorado para $endpointId: la red se está cerrando',
      );
      if (status == Status.CONNECTED) {
        unawaited(_service.disconnectFromEndpoint(endpointId));
      }
      _endpointNames.remove(endpointId);
      _discoveredEndpoints.removeWhere((e) => e.endpointId == endpointId);
      _updateCurrentState();
      notifyListeners();
      return;
    }

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
    debugPrint(
      '[NearbyProvider] onDisconnected $endpointId${manual ? ' (manual)' : ''}',
    );
    if (_pendingStopEndpoints.remove(endpointId)) {
      _log(
        'Callback de desconexión recibido; pendientes=${_pendingStopEndpoints.length}',
      );
      if (_pendingStopEndpoints.isEmpty) {
        _stopDisconnectionsCompleter?.complete();
      }
    }
    final nodeId = _connectedEndpoints[endpointId];
    _connectedEndpoints.remove(endpointId);
    _relay.removeNeighbor(endpointId);
    _connectingEndpoints.remove(endpointId);

    if (nodeId != null && !manual && _policy.isRunning) {
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
    if (!_policy.discoveryActive || nodeId == null) return;
    debugPrint(
      '[NearbyProvider] Desconexión involuntaria: reiniciando discovery',
    );
    await _service.restartDiscovery(nodeId);
  }

  void _onMessageReceived(String endpointId, String rawMessage) {
    try {
      final envelope = Envelope.decode(rawMessage);
      final result = _relay.processIncoming(endpointId, envelope);

      if (result.action == RelayAction.deliver) {
        unawaited(_persistIncomingMessage(envelope));
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

  Future<void> _persistIncomingMessage(Envelope envelope) async {
    final message = ChatMessage.fromEnvelope(envelope, isMine: false);
    try {
      if (_isBackgroundController) {
        final inserted = await MessageStorage.insert(message);
        if (!inserted) return;
        _serviceEmitter?.call('messages_changed', {'messageId': message.id});
      } else {
        await _chatProvider?.addMessage(message);
      }

      final shouldNotify =
          !_uiForeground ||
          (envelope.isBroadcast
              ? !_broadcastVisible
              : _visibleChatNodeId != envelope.fromNodeId);
      if (!shouldNotify) return;
      if (envelope.isBroadcast) {
        await localNotificationService.showSosAlert(
          envelope.fromNodeId,
          envelope.text,
        );
      } else {
        await localNotificationService.showIncomingMessage(envelope.fromNodeId);
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[NearbyProvider] No se pudo persistir el mensaje entrante: '
        '$error\n$stackTrace',
      );
    }
  }

  /// Deriva el estado de la UI del estado de la máquina y de las listas de vecinos.
  void _updateCurrentState() {
    _state = switch (_policy.state) {
      MeshState.idle =>
        _errorMessage != null ? NearbyState.error : NearbyState.idle,
      MeshState.pausedNoMedia => NearbyState.noMedia,
      _ when _connectedEndpoints.isNotEmpty => NearbyState.connected,
      MeshState.runningNoDiscovery => NearbyState.noLocation,
      _ when _connectingEndpoints.isNotEmpty => NearbyState.connecting,
      _ => NearbyState.searching,
    };
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
    if (!_isBackgroundController) {
      _backgroundService.invoke('media_state', media.toMap());
      return;
    }
    applyMediaStateInBackground(media.toMap());
  }

  void applyMediaStateInBackground(Map<dynamic, dynamic> mediaState) {
    if (!_isBackgroundController) return;
    final media = MediaState.fromMap(mediaState);
    debugPrint('[NearbyProvider] Medios: $media');
    _policy.onMediaEvent(media);
    _mediaDebounce?.cancel();
    _mediaDebounce = Timer(
      MeshRecoveryPolicy.mediaDebounce,
      () => _enqueue(_applyMediaRules),
    );
  }

  Future<void> _applyMediaRules() =>
      _execute(_policy.onMediaStable(connectedCount: connectedCount));

  /// Ejecuta la acción que decidió la máquina de estados (`MeshRecoveryPolicy`).
  /// La máquina ya pasó al nuevo estado; acá solo se actúa sobre Nearby.
  Future<void> _execute(MeshAction action) async {
    if (action != MeshAction.none) {
      debugPrint('[NearbyProvider] Red: $action -> ${_policy.state.name}');
    }
    final nodeId = _myNodeId;
    switch (action) {
      case MeshAction.none:
        break;
      case MeshAction.start:
        await _startMesh();
        return;
      case MeshAction.pause:
        _cancelSafetyTimer();
        await _safeStopAll();
        _clearNeighbors();
      case MeshAction.stopDiscovery:
        // Los enlaces y el advertising no dependen de la ubicación: se preservan.
        await _service.stopDiscovery();
        _discoveredEndpoints.clear();
      case MeshAction.startDiscovery:
        if (nodeId != null) await _service.startDiscovery(nodeId);
      case MeshAction.fullRestart:
        // Cayó el Bluetooth (los enlaces BLE murieron) o no hay enlaces que preservar.
        await _safeStopAll();
        _clearNeighbors();
        await _startMesh();
        return;
      case MeshAction.softRestart:
        // Sin stopAllEndpoints: se preservan los enlaces que sobrevivieron.
        _discoveredEndpoints.clear();
        await _restartAdvertisingAndDiscovery();
    }
    _updateCurrentState();
    notifyListeners();
  }

  Future<void> _restartAdvertisingAndDiscovery() async {
    final nodeId = _myNodeId;
    if (nodeId == null) return;
    await _service.restartAdvertising(nodeId);
    if (_policy.discoveryActive) await _service.restartDiscovery(nodeId);
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
    if (!_policy.discoveryActive || nodeId == null) return;

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

  Future<bool> _safeStopAll() async {
    try {
      await _service.stopAll();
      _log('Solicitudes para detener Nearby enviadas');
      return true;
    } catch (e) {
      _log('No se confirmó stopAll: $e');
      return false;
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
    _publishUiPresence();
    if (_isBackgroundController) return;
    if (state != AppLifecycleState.resumed || !isSearching) return;
    // Pasa por la misma espera de estabilidad que los eventos: al cambiar el
    // modo avión desde el panel rápido, la app vuelve a `resumed` en plena
    // transición de los medios y aplicar las reglas ahí reiniciaría demasiado pronto.
    unawaited(
      _mediaService.current().then((media) {
        if (media != null) _onMediaChanged(media);
      }),
    );
  }

  @override
  void dispose() {
    if (!_isBackgroundController) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _mediaSub?.cancel();
    _snapshotSub?.cancel();
    _messageSub?.cancel();
    _navigationSub?.cancel();
    _mediaDebounce?.cancel();
    _rediscoveryDebounce?.cancel();
    _cancelSafetyTimer();
    for (final timer in _connectTimers.values) {
      timer.cancel();
    }
    if (_isBackgroundController) unawaited(_safeStopAll());
    super.dispose();
  }
}
