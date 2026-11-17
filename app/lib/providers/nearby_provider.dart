import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/models/chat_message.dart';
import '../data/models/envelope.dart';
import '../services/background_mesh_service.dart';
import '../services/local_notification_service.dart';
import '../services/mesh_protocol.dart';
import '../services/nearby_permission_handler.dart';
import 'chat_provider.dart';

export '../services/mesh_protocol.dart' show NearbyState;

/// Nivel de alcanzabilidad de un nodo destino.
enum NodeReachability { direct, multihop, unreachable }

/// Estado de la red mesh para la UI.
///
/// La red corre en el servicio de fondo (`MeshController`): este provider solo
/// le manda comandos y refleja los [MeshSnapshot] que publica. El snapshot es
/// la única fuente de verdad.
class NearbyProvider extends ChangeNotifier with WidgetsBindingObserver {
  NearbyProvider() {
    WidgetsBinding.instance.addObserver(this);
    _snapshotSub = _service.on(MeshEvent.snapshot).listen(_applySnapshot);
    _messageSub = _service.on(MeshEvent.messagesChanged).listen((_) {
      unawaited(_chatProvider?.refreshFromStorage());
    });
    _serviceStoppedSub = _service
        .on(MeshEvent.serviceStopped)
        .listen((_) => _onServiceStopped());
    _navigationSub = appNavigationObserver.changes.listen((_) {
      _publishUiPresence();
    });
    _publishUiPresence();
    unawaited(_requestExistingServiceState());
  }

  final BackgroundMeshService _service = BackgroundMeshService.instance;

  // ── Estado observable ──

  NearbyState _state = NearbyState.idle;
  NearbyState get state => _state;

  /// El usuario pidió conectar y la red no volvió a `idle`.
  bool _isSearching = false;
  bool get isSearching => _isSearching;

  /// endpointId → nodeId de los vecinos conectados.
  final Map<String, String> _connectedEndpoints = {};
  Map<String, String> get connectedEndpoints =>
      Map.unmodifiable(_connectedEndpoints);
  int get connectedCount => _connectedEndpoints.length;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _myNodeId;
  String? get myNodeId => _myNodeId;

  /// El último cierre no se pudo confirmar: el servicio sigue vivo en `error`
  /// y la UI ofrece reintentar la desconexión.
  bool _stopFailed = false;
  bool get stopFailed => _stopFailed;

  // ── Espera del cierre ──

  /// Se mandó `stop_search` y todavía no llegó un snapshot con
  /// `stopping: true` ni el aviso de que el servicio se detuvo.
  bool _stopRequested = false;
  bool _stopAcknowledged = false;
  Timer? _stopWatchdog;
  static const Duration _stopUiTimeout = Duration(seconds: 15);

  ChatProvider? _chatProvider;
  StreamSubscription<Map<String, dynamic>?>? _snapshotSub;
  StreamSubscription<Map<String, dynamic>?>? _messageSub;
  StreamSubscription<Map<String, dynamic>?>? _serviceStoppedSub;
  StreamSubscription<void>? _navigationSub;

  void _log(String message) => debugPrint('[NearbyProvider] $message');

  /// Inyecta o actualiza la referencia a ChatProvider.
  void setChatProvider(ChatProvider provider) => _chatProvider = provider;

  Future<void> _requestExistingServiceState() async {
    if (await _service.isRunning()) {
      _service.invoke(MeshCommand.requestSnapshot);
    }
  }

  // ── Snapshots ──

  void _applySnapshot(Map<String, dynamic>? data) {
    if (data == null) return;
    final snapshot = MeshSnapshot.fromMap(data);
    if (_stopRequested && !snapshot.stopping && !_stopAcknowledged) {
      // Snapshot anterior a que el servicio procesara el stop_search.
      return;
    }
    if (snapshot.stopping) {
      _stopAcknowledged = true;
    } else {
      // El cierre terminó sin detener el servicio: falló o llegó un inicio.
      _endStopWait();
    }
    final previousState = _state;
    _state = snapshot.stopping ? NearbyState.disconnecting : snapshot.state;
    _stopFailed = snapshot.stopFailed;
    _isSearching = snapshot.searching;
    _myNodeId = snapshot.myNodeId;
    _errorMessage = snapshot.errorMessage;
    _connectedEndpoints
      ..clear()
      ..addAll(snapshot.connected);
    if (_state != previousState) {
      _log(
        'Estado actualizado desde el servicio: $previousState -> $_state; '
        'descubiertos=${snapshot.discovered.length}, '
        'conectados=${snapshot.connected.length}, '
        'conectando=${snapshot.connecting.length}',
      );
    }
    notifyListeners();
  }

  // ── Presencia ──

  void _publishUiPresence() {
    _service.invoke(MeshCommand.uiState, _uiPresence().toMap());
  }

  UiPresence _uiPresence() {
    final observer = appNavigationObserver;
    return UiPresence(
      foreground: observer.isForeground,
      chatNodeId: observer.visibleChatNodeId,
      broadcastVisible: observer.isBroadcastVisible,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _publishUiPresence();
  }

  // ── Consultas ──

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

  // ── Comandos ──

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

    final ready = await _service.ensureRunning();
    if (!ready) {
      _log('Conexión cancelada: servicio de fondo no confirmó inicio');
      _state = NearbyState.error;
      _errorMessage = 'No se pudo iniciar el servicio de red en segundo plano.';
      notifyListeners();
      return;
    }

    _myNodeId = nodeId;
    _service.invoke(MeshCommand.startSearch, {
      'nodeId': nodeId,
      'uiState': _uiPresence().toMap(),
    });
    _log('Comando start_search enviado');
  }

  /// Detiene todas las conexiones, advertising y discovery.
  ///
  /// No se asume el resultado: queda en `disconnecting` hasta que el servicio
  /// avise que se detuvo o mande un snapshot que diga otra cosa.
  Future<void> stopSearching() async {
    if (_state == NearbyState.disconnecting) return;
    if (!await _service.isRunning()) {
      _onServiceStopped();
      return;
    }
    _stopRequested = true;
    _stopAcknowledged = false;
    _state = NearbyState.disconnecting;
    _errorMessage = null;
    notifyListeners();
    _service.invoke(MeshCommand.stopSearch);
    _stopWatchdog?.cancel();
    _stopWatchdog = Timer(_stopUiTimeout, () => unawaited(_onStopTimeout()));
  }

  /// El servicio avisó que se detiene (o ya no corre): estado de reposo.
  void _onServiceStopped() {
    _endStopWait();
    _isSearching = false;
    _stopFailed = false;
    _state = NearbyState.idle;
    _connectedEndpoints.clear();
    _errorMessage = null;
    _log('Servicio detenido');
    notifyListeners();
  }

  /// Respaldo si el aviso del servicio nunca llega (por ejemplo, murió).
  Future<void> _onStopTimeout() async {
    if (!_stopRequested && _state != NearbyState.disconnecting) return;
    _log('Sin confirmación del cierre en ${_stopUiTimeout.inSeconds} s');
    if (!await _service.isRunning()) {
      _onServiceStopped();
      return;
    }
    _endStopWait();
    _service.invoke(MeshCommand.requestSnapshot);
  }

  void _endStopWait() {
    _stopRequested = false;
    _stopAcknowledged = false;
    _stopWatchdog?.cancel();
    _stopWatchdog = null;
  }

  /// Desconecta de un endpoint específico.
  /// TEMPORAL: el servicio además bloquea al nodo para que no se reconecte.
  Future<void> disconnectEndpoint(String endpointId) async {
    _service.invoke(MeshCommand.disconnectEndpoint, {'endpointId': endpointId});
  }

  /// Envía un mensaje 1-a-1 a un nodo destino específico.
  /// Si es vecino directo, se envía a su endpoint; si no, se propaga por flooding.
  Future<void> sendChatMessage(String targetNodeId, String text) async {
    if (_myNodeId == null || text.trim().isEmpty) return;
    await _sendEnvelope(
      Envelope.create(
        fromNodeId: _myNodeId!,
        toNodeId: targetNodeId,
        text: text.trim(),
        ttl: Envelope.defaultTtl,
      ),
    );
  }

  /// Envía un broadcast SOS a todos los vecinos conectados para propagación epidémica.
  Future<void> sendBroadcast(String text) async {
    if (_myNodeId == null || text.trim().isEmpty) return;
    await _sendEnvelope(
      Envelope.create(
        fromNodeId: _myNodeId!,
        toNodeId: Envelope.broadcastAddress,
        text: text.trim(),
        ttl: Envelope.defaultTtl,
      ),
    );
  }

  /// Guarda el mensaje propio y le pide al servicio que lo rutee.
  Future<void> _sendEnvelope(Envelope envelope) async {
    await _chatProvider?.addMessage(
      ChatMessage.fromEnvelope(envelope, isMine: true),
    );
    _service.invoke(MeshCommand.sendEnvelope, {'envelope': envelope.encode()});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _snapshotSub?.cancel();
    _messageSub?.cancel();
    _serviceStoppedSub?.cancel();
    _navigationSub?.cancel();
    _stopWatchdog?.cancel();
    super.dispose();
  }
}
