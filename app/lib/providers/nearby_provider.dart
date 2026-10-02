import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

import '../data/discovered_endpoint.dart';
import '../data/models/chat_message.dart';
import '../data/models/envelope.dart';
import '../data/nearby_service.dart';
import '../services/local_notification_service.dart';
import '../services/message_relay.dart';
import '../services/nearby_permission_handler.dart';
import 'chat_provider.dart';

/// Estados posibles del sistema Nearby Connections.
enum NearbyState { idle, searching, connecting, connected, error }

/// Nivel de alcanzabilidad de un nodo destino.
enum NodeReachability { direct, multihop, unreachable }

/// Provider que gestiona el estado de red de Nearby Connections,
/// descubrimiento continuo, multi-conexión, routing multi-hop (MessageRelay)
/// y reenvío de broadcast SOS.
class NearbyProvider extends ChangeNotifier {
  final NearbyService _service = NearbyService();

  // ── Estado observable ──

  NearbyState _state = NearbyState.idle;
  NearbyState get state => _state;

  bool _isSearching = false;
  bool get isSearching => _isSearching;

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

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _myNodeId;
  String? get myNodeId => _myNodeId;

  late MessageRelay _relay;
  ChatProvider? _chatProvider;

  // ── Constructor ──

  NearbyProvider() {
    _relay = MessageRelay(myNodeId: '');
    _setupCallbacks();
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
    _relay = MessageRelay(myNodeId: nodeId);

    // Pedir permisos en runtime
    final permissionResult =
        await PermissionService.requestPermissionsDetailed();
    if (!permissionResult.isGranted) {
      _state = NearbyState.error;
      _errorMessage = permissionResult.missingMessage;
      notifyListeners();
      return;
    }

    _discoveredEndpoints.clear();
    _errorMessage = null;
    _isSearching = true;
    _state = NearbyState.searching;
    notifyListeners();

    final advResult = await _service.startAdvertising(nodeId);
    final disResult = await _service.startDiscovery(nodeId);

    if (!advResult && !disResult) {
      _isSearching = false;
      _state = NearbyState.error;
      _errorMessage = _service.lastError ??
          'No se pudo iniciar la búsqueda. Verificá que el Bluetooth y la ubicación estén encendidos.';
      notifyListeners();
    } else if (!advResult || !disResult) {
      debugPrint(
        '[NearbyProvider] Parcialmente iniciado: adv=$advResult, dis=$disResult. Detalle: ${_service.lastError}',
      );
    }
  }

  /// Solicita conexión a un endpoint descubierto.
  Future<void> connectTo(String endpointId) async {
    if (_myNodeId == null || _connectingEndpoints.contains(endpointId)) return;

    _connectingEndpoints.add(endpointId);
    _state = NearbyState.connecting;
    notifyListeners();

    final result = await _service.requestConnection(_myNodeId!, endpointId);
    if (!result) {
      _connectingEndpoints.remove(endpointId);
      _updateCurrentState();
      notifyListeners();
    }
  }

  /// Detiene todas las conexiones, advertising y discovery.
  Future<void> stopSearching() async {
    _isSearching = false;
    await _service.stopAll();
    _connectedEndpoints.clear();
    _discoveredEndpoints.clear();
    _connectingEndpoints.clear();
    _relay.clearSeenMessages();
    _state = NearbyState.idle;
    _errorMessage = null;
    notifyListeners();
  }

  /// Desconecta de un endpoint específico.
  Future<void> disconnectEndpoint(String endpointId) async {
    await _service.disconnectFromEndpoint(endpointId);
    _onDisconnected(endpointId);
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
    final alreadyExists =
        _discoveredEndpoints.any((e) => e.endpointId == endpointId);
    if (!alreadyExists && !_connectedEndpoints.containsKey(endpointId)) {
      _discoveredEndpoints.add(
        DiscoveredEndpoint(endpointId: endpointId, userName: userName),
      );
      notifyListeners();
    }

    // Auto-conexión: para evitar colisiones cruzadas cuando ambos se descubren a la vez,
    // el nodo con ID lexicográficamente mayor inicia la solicitud.
    if (!_connectedEndpoints.containsKey(endpointId) &&
        !_connectingEndpoints.contains(endpointId) &&
        _myNodeId != null) {
      if (_myNodeId!.compareTo(userName) > 0) {
        connectTo(endpointId);
      }
    }
  }

  void _onEndpointLost(String endpointId) {
    _discoveredEndpoints.removeWhere((e) => e.endpointId == endpointId);
    notifyListeners();
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    // Aceptar conexiones entrantes automáticamente
    _service.acceptConnection(endpointId);
  }

  void _onConnectionResult(String endpointId, Status status) {
    _connectingEndpoints.remove(endpointId);

    if (status == Status.CONNECTED) {
      final endpoint = _discoveredEndpoints
          .where((e) => e.endpointId == endpointId)
          .firstOrNull;
      final nodeName = endpoint?.userName ?? endpointId;

      _connectedEndpoints[endpointId] = nodeName;
      _relay.addNeighbor(endpointId, nodeName);
      _discoveredEndpoints.removeWhere((e) => e.endpointId == endpointId);

      _updateCurrentState();
      _errorMessage = null;
    } else {
      _updateCurrentState();
    }
    notifyListeners();
  }

  void _onDisconnected(String endpointId) {
    _connectedEndpoints.remove(endpointId);
    _relay.removeNeighbor(endpointId);
    _connectingEndpoints.remove(endpointId);

    _updateCurrentState();
    notifyListeners();
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
    if (!_isSearching) {
      _state = NearbyState.idle;
    } else if (_connectedEndpoints.isNotEmpty) {
      _state = NearbyState.connected;
    } else if (_connectingEndpoints.isNotEmpty) {
      _state = NearbyState.connecting;
    } else {
      _state = NearbyState.searching;
    }
  }

  @override
  void dispose() {
    _service.stopAll();
    super.dispose();
  }
}
