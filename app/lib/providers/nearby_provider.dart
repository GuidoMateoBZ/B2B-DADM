import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/discovered_endpoint.dart';
import '../data/message_repository.dart';
import '../data/models/chat_message.dart';
import '../data/models/envelope.dart';
import '../services/background_mesh_service.dart';
import '../services/local_notification_service.dart';
import '../services/nearby_permission_handler.dart';
import 'chat_provider.dart';

/// Estados posibles del sistema Nearby Connections.
enum NearbyState { idle, searching, connecting, connected, error }

/// Nivel de alcanzabilidad de un nodo destino.
enum NodeReachability { direct, multihop, unreachable }

/// Adaptador de estado para la UI; la sesión Nearby vive en el servicio Android.
class NearbyProvider extends ChangeNotifier {
  NearbyProvider({
    MessageRepository? repository,
    BackgroundMeshService? meshService,
  }) : _repository = repository ?? MessageRepository(),
       _meshService = meshService ?? BackgroundMeshService.instance {
    _stateSubscription = _meshService.states.listen(_applyState);
    _errorSubscription = _meshService.errors.listen(_applyError);
    _requestStateIfServiceIsRunning();
  }

  final MessageRepository _repository;
  final BackgroundMeshService _meshService;

  StreamSubscription<Map<String, dynamic>?>? _stateSubscription;
  StreamSubscription<Map<String, dynamic>?>? _errorSubscription;
  ChatProvider? _chatProvider;

  NearbyState _state = NearbyState.idle;
  NearbyState get state => _state;

  bool _isSearching = false;
  bool get isSearching => _isSearching;

  final List<DiscoveredEndpoint> _discoveredEndpoints = [];
  List<DiscoveredEndpoint> get discoveredEndpoints =>
      List.unmodifiable(_discoveredEndpoints);

  final Map<String, String> _connectedEndpoints = {};
  Map<String, String> get connectedEndpoints =>
      Map.unmodifiable(_connectedEndpoints);

  int get connectedCount => _connectedEndpoints.length;
  List<String> get connectedNodeIds => _connectedEndpoints.values.toList();

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String? _myNodeId;
  String? get myNodeId => _myNodeId;

  void setChatProvider(ChatProvider provider) {
    _chatProvider = provider;
  }

  Future<void> _requestStateIfServiceIsRunning() async {
    try {
      if (await _meshService.isRunning()) {
        _meshService.requestCurrentState();
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[NearbyProvider] No se pudo consultar el servicio: $error\n$stackTrace',
      );
      _applyError({
        'message': 'No se pudo consultar el servicio de red: $error',
      });
    }
  }

  void _applyState(Map<String, dynamic>? data) {
    if (data == null) return;

    final stateName = data['state'];
    if (stateName is String) {
      _state = NearbyState.values.firstWhere(
        (state) => state.name == stateName,
        orElse: () => NearbyState.error,
      );
    }
    _isSearching = data['isSearching'] == true;
    _myNodeId = data['nodeId'] as String?;
    _errorMessage = data['errorMessage'] as String?;

    _discoveredEndpoints
      ..clear()
      ..addAll(
        (data['discoveredEndpoints'] as List<dynamic>? ?? const [])
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (endpoint) => DiscoveredEndpoint(
                endpointId: endpoint['endpointId'] as String,
                userName: endpoint['userName'] as String,
              ),
            ),
      );

    _connectedEndpoints
      ..clear()
      ..addAll(
        (data['connectedEndpoints'] as Map<dynamic, dynamic>? ?? const {}).map(
          (endpointId, nodeId) =>
              MapEntry(endpointId as String, nodeId as String),
        ),
      );
    notifyListeners();
  }

  void _applyError(Map<String, dynamic>? data) {
    final message = data?['message'];
    if (message is! String || message.isEmpty) return;
    _errorMessage = message;
    notifyListeners();
  }

  /// Solicita permisos en la UI y luego inicia la sesión foreground Android.
  Future<void> startSearching(String nodeId) async {
    _myNodeId = nodeId;
    _errorMessage = null;

    if (!Platform.isAndroid) {
      _state = NearbyState.error;
      _errorMessage =
          'La conexión mesh en segundo plano solo está disponible en Android.';
      notifyListeners();
      return;
    }

    final permissionResult =
        await PermissionService.requestPermissionsDetailed();
    if (!permissionResult.isGranted) {
      _state = NearbyState.error;
      _errorMessage = permissionResult.missingMessage;
      notifyListeners();
      return;
    }

    await localNotificationService.requestPermission();

    _discoveredEndpoints.clear();
    _connectedEndpoints.clear();
    _state = NearbyState.searching;
    _isSearching = true;
    notifyListeners();

    try {
      await _meshService.start(nodeId);
    } catch (error, stackTrace) {
      debugPrint(
        '[NearbyProvider] No se pudo iniciar el servicio: $error\n$stackTrace',
      );
      _state = NearbyState.error;
      _isSearching = false;
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  Future<void> connectTo(String endpointId) async {
    if (!_isSearching) return;
    _meshService.connectTo(endpointId);
  }

  Future<void> stopSearching() async {
    _isSearching = false;
    _state = NearbyState.idle;
    _discoveredEndpoints.clear();
    _connectedEndpoints.clear();
    _errorMessage = null;
    notifyListeners();
    _meshService.stop();
  }

  Future<void> disconnectEndpoint(String endpointId) async {
    _meshService.disconnectEndpoint(endpointId);
  }

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

  Future<void> sendChatMessage(String targetNodeId, String text) async {
    final nodeId = _myNodeId;
    if (nodeId == null || text.trim().isEmpty) return;

    final envelope = Envelope.create(
      fromNodeId: nodeId,
      toNodeId: targetNodeId,
      text: text.trim(),
    );
    await _saveAndSend(envelope);
  }

  Future<void> sendBroadcast(String text) async {
    final nodeId = _myNodeId;
    if (nodeId == null || text.trim().isEmpty) return;

    final envelope = Envelope.create(
      fromNodeId: nodeId,
      toNodeId: Envelope.broadcastAddress,
      text: text.trim(),
    );
    await _saveAndSend(envelope);
  }

  Future<void> _saveAndSend(Envelope envelope) async {
    final message = ChatMessage.fromEnvelope(envelope, isMine: true);
    final inserted = await _repository.insert(message);
    if (inserted) {
      await _chatProvider?.refreshFromStorage(message.receiverId);
    }

    if (_isSearching) {
      _meshService.sendEnvelope(envelope.encode());
    }
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _errorSubscription?.cancel();
    super.dispose();
  }
}
