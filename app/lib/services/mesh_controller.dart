import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/discovered_endpoint.dart';
import '../data/message_storage.dart';
import '../data/models/chat_message.dart';
import '../data/models/envelope.dart';
import '../data/models/media_state.dart';
import '../data/nearby_service.dart';
import '../data/node_id_storage.dart';
import 'local_notification_service.dart';
import 'media_state_service.dart';
import 'mesh_protocol.dart';
import 'mesh_recovery_policy.dart';
import 'message_relay.dart';

/// Emite un evento del protocolo hacia la UI.
typedef MeshEmitter = void Function(String event, [Map<String, dynamic>? data]);

/// Lógica de la red mesh que corre en el isolate del servicio de fondo.
///
/// Es dueño de Nearby ([NearbyService]), de la máquina de estados
/// ([MeshRecoveryPolicy]), del ruteo ([MessageRelay]) y de los timers. Tras
/// cada cambio publica un [MeshSnapshot] con [MeshEvent.snapshot].
class MeshController {
  MeshController({
    this._emit,
    NearbyService? nearby,
    MediaStateService? mediaService,
    this.stopDisconnectionTimeout = const Duration(seconds: 5),
    this.stopDrainPeriod = const Duration(seconds: 2),
  }) : _service = nearby ?? NearbyService(),
       _mediaService = mediaService ?? MediaStateService() {
    _setupCallbacks();
    // El plugin de medios está registrado también en el engine del servicio:
    // los cambios llegan aunque la app esté cerrada.
    _mediaSub = _mediaService.stream.listen(
      _onMediaChanged,
      onError: (Object e) => _log('Error en observer de medios: $e'),
    );
  }

  static const String activeSessionKey = 'mesh_session_active';

  final MeshEmitter? _emit;
  final NearbyService _service;
  final MediaStateService _mediaService;
  final MeshRecoveryPolicy _policy = MeshRecoveryPolicy();
  MessageRelay _relay = MessageRelay(myNodeId: '');

  /// Espera máxima de los `onDisconnected` al cerrar con enlaces activos.
  final Duration stopDisconnectionTimeout;

  /// Espera tras el cierre para que lleguen callbacks nativos tardíos.
  final Duration stopDrainPeriod;

  // ── Estado ──

  NearbyState _state = NearbyState.idle;
  NearbyState get state => _state;

  /// El usuario pidió conectar: la máquina de estados no está en `idle`.
  bool get isSearching => _policy.state != MeshState.idle;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _myNodeId;
  String? get myNodeId => _myNodeId;

  final List<DiscoveredEndpoint> _discoveredEndpoints = [];

  /// endpointId → nodeId
  final Map<String, String> _connectedEndpoints = {};
  Map<String, String> get connectedEndpoints =>
      Map.unmodifiable(_connectedEndpoints);
  int get connectedCount => _connectedEndpoints.length;

  final Set<String> _connectingEndpoints = {};

  /// endpointId → nodeId, cargado en onEndpointFound y onConnectionInitiated.
  final Map<String, String> _endpointNames = {};

  /// Intento de conexión programado (fallback del iniciador o reconexión).
  final Map<String, Timer> _connectTimers = {};

  UiPresence _uiPresence = const UiPresence();

  StreamSubscription<MediaState>? _mediaSub;
  Timer? _mediaDebounce;
  Timer? _safetyTimer;
  Timer? _rediscoveryDebounce;

  /// Serializa las operaciones que tocan Nearby (inicio, pausas, reinicios).
  Future<void> _opChain = Future.value();

  // ── Cierre ──

  final Set<String> _pendingStopEndpoints = {};
  Completer<void>? _stopDisconnectionsCompleter;

  /// Se ignoran los callbacks de Nearby porque la red se está cerrando.
  bool _isStoppingMesh = false;

  /// `start_search` recibidos que todavía no terminaron (pueden estar
  /// encolados detrás de un cierre).
  int _pendingStarts = 0;
  bool get hasPendingStart => _pendingStarts > 0;

  /// Hay un cierre en curso o terminado (hasta que el servicio muera o llegue
  /// un inicio nuevo). Viaja en el snapshot como `stopping`.
  bool _stopInProgress = false;

  /// El último cierre no se pudo confirmar: el servicio sigue vivo en `error`.
  bool _stopFailed = false;
  bool get stopFailed => _stopFailed;

  /// Tras un cierre confirmado, el servicio puede detenerse si no quedó una
  /// sesión activa ni un inicio encolado.
  bool get canStopService => !isSearching && !hasPendingStart;

  void _log(String message) => debugPrint('[MeshController] $message');

  // ── Snapshot ──

  MeshSnapshot get snapshot => MeshSnapshot(
    state: _state,
    searching: isSearching,
    myNodeId: _myNodeId,
    errorMessage: _errorMessage,
    discovered: [
      for (final e in _discoveredEndpoints)
        (endpointId: e.endpointId, userName: e.userName),
    ],
    connected: Map<String, String>.from(_connectedEndpoints),
    connecting: _connectingEndpoints.toList(),
    stopping: _stopInProgress,
    stopFailed: _stopFailed,
  );

  void emitSnapshot() => _emit?.call(MeshEvent.snapshot, snapshot.toMap());

  void _changed() => emitSnapshot();

  // ── Ciclo de vida ──

  /// Restaura la sesión si el servicio revivió con la red activa.
  Future<void> initialize() async {
    await localNotificationService.initialize(background: true);
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(activeSessionKey) != true) return;

    final nodeId = await NodeIdStorage().getId();
    // Sesión restaurada: la policy decide con los medios actuales.
    final media = await _mediaService.current();
    if (media != null) _policy.onMediaEvent(media);
    final action = _policy.connect();
    _myNodeId = nodeId;
    _relay = MessageRelay(myNodeId: nodeId);
    await _execute(action);
  }

  void updateUiPresence(UiPresence presence) => _uiPresence = presence;

  void dispose() {
    _mediaSub?.cancel();
    _mediaDebounce?.cancel();
    _rediscoveryDebounce?.cancel();
    _cancelSafetyTimer();
    for (final timer in _connectTimers.values) {
      timer.cancel();
    }
    _connectTimers.clear();
    unawaited(_safeStopAll());
  }

  void _setupCallbacks() {
    _service.onEndpointFound = _onEndpointFound;
    _service.onEndpointLost = _onEndpointLost;
    _service.onConnectionInitiated = _onConnectionInitiated;
    _service.onConnectionResult = _onConnectionResult;
    _service.onDisconnected = _onDisconnected;
    _service.onMessageReceived = _onMessageReceived;
  }

  // ── Comandos ──

  /// `start_search`. Todo el inicio va dentro de la cola: si hay un cierre en
  /// curso, se evalúa el estado recién cuando terminó.
  Future<void> startSearching(
    String nodeId, {
    MediaState? initialMedia,
    UiPresence? uiPresence,
  }) async {
    _log('Procesando start_search');
    if (uiPresence != null) updateUiPresence(uiPresence);
    _pendingStarts++;
    try {
      await _enqueue(() async {
        if (_myNodeId == nodeId && _policy.state != MeshState.idle) {
          _log('start_search ignorado: sesión ya activa');
          emitSnapshot();
          return;
        }
        _isStoppingMesh = false;
        _stopInProgress = false;
        _stopFailed = false;
        _relay = MessageRelay(myNodeId: nodeId);
        _policy.clearBlocks();
        _errorMessage = null;
        _discoveredEndpoints.clear();
        _myNodeId = nodeId;
        await (await SharedPreferences.getInstance()).setBool(
          activeSessionKey,
          true,
        );
        final media = initialMedia ?? await _mediaService.current();
        if (media != null) _policy.onMediaEvent(media);
        await _execute(_policy.connect());
      });
    } finally {
      _pendingStarts--;
    }
  }

  /// `stop_search`. Espera los `onDisconnected` de los enlaces activos y un
  /// margen para callbacks tardíos. Devuelve si el cierre se confirmó.
  Future<bool> stopSearching() async {
    _isStoppingMesh = true;
    _stopInProgress = true;
    _stopFailed = false;
    emitSnapshot();
    await (await SharedPreferences.getInstance()).setBool(
      activeSessionKey,
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
            stopDisconnectionTimeout,
          );
        } on TimeoutException {
          stopped = false;
          _log(
            'No llegaron las desconexiones de '
            '${_pendingStopEndpoints.join(', ')} en '
            '${stopDisconnectionTimeout.inSeconds} s',
          );
        }
      }
      if (stopped) {
        _log(
          'Esperando ${stopDrainPeriod.inMilliseconds} ms para callbacks nativos tardíos',
        );
        await Future<void>.delayed(stopDrainPeriod);
      }
      _pendingStopEndpoints.clear();
      _stopDisconnectionsCompleter = null;
      _clearNeighbors();
      _relay.clearSeenMessages();
      _errorMessage = stopped
          ? null
          : 'No se pudo confirmar el cierre de la red Nearby.';
      _state = stopped ? NearbyState.idle : NearbyState.error;
      // Con éxito sigue en true hasta que el servicio muera o llegue un inicio.
      _stopInProgress = stopped;
      _stopFailed = !stopped;
      _changed();
    });
    return stopped;
  }

  /// `disconnect_endpoint`. TEMPORAL: además bloquea al nodo para que ninguno
  /// de los dos lo reconecte.
  Future<void> disconnectEndpoint(String endpointId) async {
    final nodeId = _connectedEndpoints[endpointId];
    if (nodeId != null) _policy.blockNode(nodeId);
    await _service.disconnectFromEndpoint(endpointId);
    _onDisconnected(endpointId, manual: true);
  }

  /// `send_envelope`: rutea un mensaje ya guardado por la UI.
  Future<void> sendEnvelope(String encodedEnvelope) async {
    final envelope = Envelope.decode(encodedEnvelope);
    final targets = _relay.getTargetEndpoints(envelope);
    if (targets.isNotEmpty) {
      _log('Enviando ${envelope.messageId} a endpoints: $targets');
      await _service.sendToEndpoints(targets, envelope.encode());
    } else {
      _log('No hay vecinos conectados para rutear ${envelope.messageId}');
    }
  }

  // ── Inicio de Nearby ──

  /// Inicia advertising y, si la máquina está en `running`, también discovery.
  /// Lo usan el inicio y los reinicios automáticos.
  Future<void> _startMesh() async {
    final nodeId = _myNodeId;
    if (nodeId == null) return;

    _log('Iniciando advertising y discovery=${_policy.discoveryActive}');
    _errorMessage = null;
    _updateCurrentState();
    _changed();

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
      _changed();
      return;
    }
    if (!advResult || !disResult) {
      _log(
        'Parcialmente iniciado: adv=$advResult, dis=$disResult. Detalle: ${_service.lastError}',
      );
    }

    _startSafetyTimer();
    _updateCurrentState();
    _log(
      'Inicio finalizado: adv=$advResult, discovery=$disResult, estado=$_state'
      '${_service.lastError == null ? '' : ', detalle=${_service.lastError}'}',
    );
    _changed();
  }

  /// Solicita conexión a un endpoint descubierto.
  ///
  /// Con [rediscoverOnFailure] (reconexiones), si el intento falla se reinicia
  /// el discovery una vez: el endpointId guardado puede ya no ser válido.
  Future<void> _connectTo(
    String endpointId, {
    bool rediscoverOnFailure = false,
  }) async {
    if (_myNodeId == null || _connectingEndpoints.contains(endpointId)) return;

    _log('Solicitando conexión con endpoint=$endpointId');
    _connectingEndpoints.add(endpointId);
    _state = NearbyState.connecting;
    _changed();

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
      _log(
        '8003 con $endpointId sin enlace en la app: liberando y reintentando',
      );
      await _service.disconnectFromEndpoint(endpointId);
      await Future<void>.delayed(NearbyService.restartPause);
      result = await _service.requestConnection(_myNodeId!, endpointId);
      _log('Resultado del reintento a $endpointId: $result');
    }
    if (result != ConnectionRequestResult.requested) {
      _log(
        'requestConnection a $endpointId: $result '
        '(código ${_service.lastErrorCode}, ${_service.lastError})',
      );
      _connectingEndpoints.remove(endpointId);
      if (rediscoverOnFailure && result == ConnectionRequestResult.failed) {
        _scheduleRediscovery();
      }
      _updateCurrentState();
      _changed();
    }
  }

  // ── Callbacks de NearbyService ──

  void _onEndpointFound(String endpointId, String userName) {
    if (_isStoppingMesh) {
      _log('Ignorando endpoint=$endpointId: la red está cerrándose');
      return;
    }
    _log('onEndpointFound $endpointId ($userName)');
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
      _changed();
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
      _log('$nodeId bloqueado (desconexión manual): no se conecta');
      return;
    }
    if (afterDisconnect) {
      final delay = MeshRecoveryPolicy.reconnectDelay(myNodeId, nodeId);
      _log(
        'Reconexión a $endpointId ($nodeId) programada en ${delay.inSeconds} s',
      );
      _scheduleConnectAttempt(endpointId, delay, afterDisconnect: true);
    } else if (MeshRecoveryPolicy.isPrimaryInitiator(myNodeId, nodeId)) {
      _connectTo(endpointId);
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
        _log('Conexión a $endpointId cancelada: ya no está visible');
      } else if (_policy.isRunning &&
          !_connectedEndpoints.containsKey(endpointId) &&
          !_connectingEndpoints.contains(endpointId) &&
          !(nodeId != null && _policy.isBlocked(nodeId))) {
        _log(
          'Conectando a $endpointId (${afterDisconnect ? 'reconexión' : 'fallback del iniciador'})',
        );
        _connectTo(endpointId, rediscoverOnFailure: afterDisconnect);
      }
    });
  }

  void _onEndpointLost(String endpointId) {
    _log('onEndpointLost $endpointId');
    if (_connectTimers.remove(endpointId) != null) {
      _log('Reconexión cancelada: onEndpointLost');
    }

    _discoveredEndpoints.removeWhere((e) => e.endpointId == endpointId);
    if (!_connectedEndpoints.containsKey(endpointId)) {
      _endpointNames.remove(endpointId);
    }
    _changed();
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
      _log('Conexión rechazada: nodo bloqueado ($nodeId)');
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
    _log('onConnectionResult $endpointId: $status');
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
      _changed();
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
    _changed();
  }

  void _onDisconnected(String endpointId, {bool manual = false}) {
    _log('onDisconnected $endpointId${manual ? ' (manual)' : ''}');
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
    _changed();
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
    _log('Desconexión involuntaria: reiniciando discovery');
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
        _log(
          'Reenviando mensaje ${result.envelope.messageId} (TTL ${result.envelope.ttl}) a: ${result.forwardTo}',
        );
        _service.sendToEndpoints(result.forwardTo, result.envelope.encode());
      }
    } catch (e, stack) {
      _log('Error procesando mensaje de $endpointId: $e\n$stack');
    }
  }

  Future<void> _persistIncomingMessage(Envelope envelope) async {
    final message = ChatMessage.fromEnvelope(envelope, isMine: false);
    try {
      final inserted = await MessageStorage.insert(message);
      if (!inserted) return;
      _emit?.call(MeshEvent.messagesChanged, {'messageId': message.id});

      final ui = _uiPresence;
      final shouldNotify =
          !ui.foreground ||
          (envelope.isBroadcast
              ? !ui.broadcastVisible
              : ui.chatNodeId != envelope.fromNodeId);
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
      _log('No se pudo persistir el mensaje entrante: $error\n$stackTrace');
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
        _log('Error en operación de red: $e\n$stack');
      }
    });
    return _opChain;
  }

  void _onMediaChanged(MediaState media) {
    _log('Medios: $media');
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
      _log('Red: $action -> ${_policy.state.name}');
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
    _changed();
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

  static const String _safetyDiscoveryErrorPrefix =
      'No se pudo reiniciar la búsqueda de vecinos: ';

  /// Control de seguridad: cubre al dispositivo que no tuvo el cambio de medio.
  Future<void> _safetyCheck() async {
    final nodeId = _myNodeId;
    if (!_policy.discoveryActive || nodeId == null) return;

    final action = _policy.onSafetyTick(connectedCount: connectedCount);
    if (action == SafetyAction.none) return;

    _log('Control de seguridad -> $action');
    // Tras reiniciar el discovery no llegan onEndpointLost: se descartan las
    // entradas viejas y las conexiones trabadas.
    _discoveredEndpoints.clear();
    _connectingEndpoints.clear();
    _updateCurrentState();
    _changed();

    if (action == SafetyAction.restartDiscoveryAndAdvertising) {
      await _service.restartAdvertising(nodeId);
    }
    _service.lastError = null;
    final restarted = await _service.restartDiscovery(nodeId);
    // El fallo no cambia el estado de la policy: solo queda visible en el
    // snapshot hasta el próximo reinicio exitoso.
    if (!restarted) {
      _errorMessage =
          '$_safetyDiscoveryErrorPrefix'
          '${_service.lastError ?? 'error desconocido'}';
      _log('Control de seguridad: $_errorMessage');
      _changed();
    } else if (_errorMessage?.startsWith(_safetyDiscoveryErrorPrefix) ??
        false) {
      _errorMessage = null;
      _changed();
    }
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
}
