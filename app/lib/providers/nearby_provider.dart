import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

import '../data/chat_message.dart';
import '../data/discovered_endpoint.dart';
import '../data/nearby_service.dart';
import '../services/nearby_permission_handler.dart';

/// Estados posibles del sistema Nearby Connections.
enum NearbyState { idle, searching, connecting, connected, error }

/// Provider que gestiona el estado reactivo de Nearby Connections.
/// La UI observa este provider con `context.watch<NearbyProvider>()`.
class NearbyProvider extends ChangeNotifier {
  final NearbyService _service = NearbyService();

  // ── Estado observable ──

  NearbyState _state = NearbyState.idle;
  NearbyState get state => _state;

  final List<DiscoveredEndpoint> _discoveredEndpoints = [];
  List<DiscoveredEndpoint> get discoveredEndpoints =>
      List.unmodifiable(_discoveredEndpoints);

  String? _connectedEndpointId;
  String? get connectedEndpointId => _connectedEndpointId;

  String? _connectedEndpointName;
  String? get connectedEndpointName => _connectedEndpointName;

  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  /// Node ID propio (se recibe desde afuera al iniciar búsqueda).
  String? _myNodeId;

  // ── Constructor ──

  NearbyProvider() {
    _setupCallbacks();
  }

  /// Configura todos los callbacks del NearbyService.
  void _setupCallbacks() {
    _service.onEndpointFound = _onEndpointFound;
    _service.onEndpointLost = _onEndpointLost;
    _service.onConnectionInitiated = _onConnectionInitiated;
    _service.onConnectionResult = _onConnectionResult;
    _service.onDisconnected = _onDisconnected;
    _service.onMessageReceived = _onMessageReceived;
  }

  // ── Métodos públicos para la UI ──

  /// Solicita permisos, arranca advertising + discovery.
  /// [nodeId] es el Node ID persistente de este dispositivo.
  Future<void> startSearching(String nodeId) async {
    _myNodeId = nodeId;

    // Pedir permisos en runtime
    final granted = await PermissionService.requestNearbyPermissions();
    if (!granted) {
      _state = NearbyState.error;
      _errorMessage = 'Se necesitan todos los permisos para usar Nearby Chat.';
      notifyListeners();
      return;
    }

    // Limpiar estado previo
    _discoveredEndpoints.clear();
    _errorMessage = null;
    _state = NearbyState.searching;
    notifyListeners();

    // Iniciar advertising y discovery en paralelo
    final advResult = await _service.startAdvertising(nodeId);
    final disResult = await _service.startDiscovery(nodeId);

    if (!advResult && !disResult) {
      _state = NearbyState.error;
      _errorMessage = 'No se pudo iniciar la búsqueda. Verificá que el Bluetooth y el GPS estén encendidos.';
      notifyListeners();
    }
  }

  /// Solicita conexión a un endpoint descubierto.
  Future<void> connectTo(String endpointId) async {
    if (_myNodeId == null) return;

    _state = NearbyState.connecting;
    _errorMessage = null;
    notifyListeners();

    final result = await _service.requestConnection(_myNodeId!, endpointId);
    if (!result) {
      _state = NearbyState.searching;
      _errorMessage = 'No se pudo solicitar la conexión.';
      notifyListeners();
    }
  }

  /// Envía un mensaje de texto al endpoint conectado.
  void sendMessage(String text) {
    if (_connectedEndpointId == null || _myNodeId == null || text.trim().isEmpty) {
      return;
    }

    final message = ChatMessage(
      text: text.trim(),
      senderNodeId: _myNodeId!,
      receiverEndpointId: _connectedEndpointId!,
      timestamp: DateTime.now(),
      isMine: true,
    );

    _messages.add(message);
    notifyListeners();

    _service.sendMessage(_connectedEndpointId!, text.trim());
  }

  /// Se desconecta del endpoint actual y vuelve a estado idle.
  Future<void> disconnect() async {
    if (_connectedEndpointId != null) {
      await _service.disconnectFromEndpoint(_connectedEndpointId!);
    }
    _connectedEndpointId = null;
    _connectedEndpointName = null;
    _messages.clear();
    _state = NearbyState.idle;
    notifyListeners();
  }

  /// Detiene advertising + discovery y limpia todo.
  Future<void> stopSearching() async {
    await _service.stopAdvertising();
    await _service.stopDiscovery();
    _discoveredEndpoints.clear();
    _state = NearbyState.idle;
    _errorMessage = null;
    notifyListeners();
  }

  // ── Callbacks del NearbyService ──

  void _onEndpointFound(String endpointId, String userName) {
    // Evitar duplicados
    final alreadyExists = _discoveredEndpoints.any(
      (e) => e.endpointId == endpointId,
    );
    if (!alreadyExists) {
      _discoveredEndpoints.add(
        DiscoveredEndpoint(endpointId: endpointId, userName: userName),
      );
      notifyListeners();
    }
  }

  void _onEndpointLost(String endpointId) {
    _discoveredEndpoints.removeWhere((e) => e.endpointId == endpointId);
    notifyListeners();
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    // Aceptar conexiones automáticamente (Hito 1, simplificado).
    // En producción se podría pedir confirmación al usuario.
    _service.acceptConnection(endpointId);
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      // Buscar el nombre del endpoint entre los descubiertos
      final endpoint = _discoveredEndpoints
          .where((e) => e.endpointId == endpointId)
          .firstOrNull;

      _connectedEndpointId = endpointId;
      _connectedEndpointName = endpoint?.userName ?? endpointId;
      _messages.clear();
      _state = NearbyState.connected;

      // Dejar de buscar una vez conectado (Hito 1 = 1-a-1)
      _service.stopAdvertising();
      _service.stopDiscovery();
      _discoveredEndpoints.clear();
    } else {
      _state = NearbyState.searching;
      _errorMessage = 'La conexión fue rechazada o falló.';
    }
    notifyListeners();
  }

  void _onDisconnected(String endpointId) {
    if (endpointId == _connectedEndpointId) {
      _connectedEndpointId = null;
      _connectedEndpointName = null;
      _messages.clear();
      _state = NearbyState.idle;
      notifyListeners();
    }
  }

  void _onMessageReceived(String endpointId, String message) {
    final chatMessage = ChatMessage(
      text: message,
      senderNodeId: endpointId,
      receiverEndpointId: _myNodeId ?? '',
      timestamp: DateTime.now(),
      isMine: false,
    );

    _messages.add(chatMessage);
    notifyListeners();
  }

  // ── Cleanup ──

  @override
  void dispose() {
    _service.stopAll();
    super.dispose();
  }
}
