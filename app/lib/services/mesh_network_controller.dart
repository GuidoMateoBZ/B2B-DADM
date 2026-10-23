import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

import '../data/discovered_endpoint.dart';
import '../data/message_repository.dart';
import '../data/models/chat_message.dart';
import '../data/models/envelope.dart';
import '../data/nearby_service.dart';
import 'local_notification_service.dart';
import 'message_relay.dart';

class MeshNetworkController {
  MeshNetworkController({
    required this._repository,
    required this._publishState,
    required this._publishMessageChange,
    required this._publishError,
  }) {
    _service.onEndpointFound = _onEndpointFound;
    _service.onEndpointLost = _onEndpointLost;
    _service.onConnectionInitiated = _onConnectionInitiated;
    _service.onConnectionResult = _onConnectionResult;
    _service.onDisconnected = _onDisconnected;
    _service.onMessageReceived = _onMessageReceived;
  }

  final NearbyService _service = NearbyService();
  final MessageRepository _repository;
  final void Function(Map<String, dynamic>) _publishState;
  final void Function(String receiverId) _publishMessageChange;
  final void Function(String message) _publishError;

  final List<DiscoveredEndpoint> _discoveredEndpoints = [];
  final Map<String, String> _connectedEndpoints = {};
  final Set<String> _connectingEndpoints = {};

  late MessageRelay _relay = MessageRelay(myNodeId: '');
  String? _myNodeId;
  String? _errorMessage;
  bool _isSearching = false;
  String _state = 'idle';

  Future<bool> start(String nodeId) async {
    if (_isSearching && _myNodeId == nodeId) {
      _publish();
      return true;
    }

    _myNodeId = nodeId;
    _relay = MessageRelay(myNodeId: nodeId);
    _discoveredEndpoints.clear();
    _errorMessage = null;
    _isSearching = true;
    _state = 'searching';
    _publish();

    final advertisingStarted = await _service.startAdvertising(nodeId);
    final discoveryStarted = await _service.startDiscovery(nodeId);

    if (!advertisingStarted && !discoveryStarted) {
      _isSearching = false;
      _state = 'error';
      _errorMessage = _service.lastError ?? 'No se pudo iniciar Nearby.';
      _publish();
      _publishError(_errorMessage!);
      return false;
    }

    if (!advertisingStarted || !discoveryStarted) {
      _publishError(
        _service.lastError ??
            'Nearby se inició parcialmente (anuncio/búsqueda).',
      );
    }
    _updateState();
    _publish();
    return true;
  }

  Future<void> stop() async {
    _isSearching = false;
    await _service.stopAll();
    _connectedEndpoints.clear();
    _discoveredEndpoints.clear();
    _connectingEndpoints.clear();
    _relay.clearSeenMessages();
    _state = 'idle';
    _errorMessage = null;
    _publish();
  }

  Future<void> disconnectEndpoint(String endpointId) async {
    await _service.disconnectFromEndpoint(endpointId);
    _onDisconnected(endpointId);
  }

  Future<void> connectTo(String endpointId) => _connectTo(endpointId);

  Future<void> sendEnvelope(String encodedEnvelope) async {
    try {
      final envelope = Envelope.decode(encodedEnvelope);
      final targets = _relay.getTargetEndpoints(envelope);
      if (targets.isNotEmpty) {
        await _service.sendToEndpoints(targets, envelope.encode());
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[MeshNetworkController] Error enviando mensaje: $error\n$stackTrace',
      );
      _publishError('No se pudo enviar el mensaje: $error');
    }
  }

  void publishCurrentState() => _publish();

  void _onEndpointFound(String endpointId, String userName) {
    final alreadyExists = _discoveredEndpoints.any(
      (endpoint) => endpoint.endpointId == endpointId,
    );
    if (!alreadyExists && !_connectedEndpoints.containsKey(endpointId)) {
      _discoveredEndpoints.add(
        DiscoveredEndpoint(endpointId: endpointId, userName: userName),
      );
      _publish();
    }

    if (!_connectedEndpoints.containsKey(endpointId) &&
        !_connectingEndpoints.contains(endpointId) &&
        _myNodeId != null &&
        _myNodeId!.compareTo(userName) > 0) {
      unawaited(_connectTo(endpointId));
    }
  }

  void _onEndpointLost(String endpointId) {
    _discoveredEndpoints.removeWhere(
      (endpoint) => endpoint.endpointId == endpointId,
    );
    _publish();
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    unawaited(_acceptConnection(endpointId));
  }

  Future<void> _acceptConnection(String endpointId) async {
    final accepted = await _service.acceptConnection(endpointId);
    if (!accepted) {
      _publishError('No se pudo aceptar la conexión con $endpointId.');
    }
  }

  void _onConnectionResult(String endpointId, Status status) {
    _connectingEndpoints.remove(endpointId);

    if (status == Status.CONNECTED) {
      final endpoint = _discoveredEndpoints
          .where((candidate) => candidate.endpointId == endpointId)
          .firstOrNull;
      final nodeName = endpoint?.userName ?? endpointId;
      _connectedEndpoints[endpointId] = nodeName;
      _relay.addNeighbor(endpointId, nodeName);
      _discoveredEndpoints.removeWhere(
        (candidate) => candidate.endpointId == endpointId,
      );
      _errorMessage = null;
    }

    _updateState();
    _publish();
  }

  void _onDisconnected(String endpointId) {
    _connectedEndpoints.remove(endpointId);
    _relay.removeNeighbor(endpointId);
    _connectingEndpoints.remove(endpointId);
    _updateState();
    _publish();
  }

  void _onMessageReceived(String endpointId, String rawMessage) {
    unawaited(_processIncoming(endpointId, rawMessage));
  }

  Future<void> _processIncoming(String endpointId, String rawMessage) async {
    late final Envelope envelope;
    late final RelayResult result;
    try {
      envelope = Envelope.decode(rawMessage);
      result = _relay.processIncoming(endpointId, envelope);
    } catch (error, stackTrace) {
      debugPrint(
        '[MeshNetworkController] Error procesando mensaje de $endpointId: '
        '$error\n$stackTrace',
      );
      _publishError('No se pudo procesar un mensaje recibido: $error');
      return;
    }

    if (result.action == RelayAction.deliver) {
      final message = ChatMessage.fromEnvelope(envelope, isMine: false);
      try {
        final inserted = await _repository.insert(message);
        if (inserted) {
          _publishMessageChange(message.receiverId);
          if (envelope.isBroadcast) {
            await localNotificationService.showSosAlertFromBackground(
              envelope.fromNodeId,
              envelope.text,
            );
          } else {
            await localNotificationService.showIncomingMessageFromBackground(
              envelope.fromNodeId,
            );
          }
        }
      } catch (error, stackTrace) {
        debugPrint(
          '[MeshNetworkController] No se pudo guardar el mensaje: '
          '$error\n$stackTrace',
        );
        _publishError('No se pudo guardar un mensaje recibido: $error');
      }
    }

    if (result.forwardTo.isNotEmpty) {
      try {
        await _service.sendToEndpoints(
          result.forwardTo,
          result.envelope.encode(),
        );
      } catch (error, stackTrace) {
        debugPrint(
          '[MeshNetworkController] No se pudo reenviar el mensaje: '
          '$error\n$stackTrace',
        );
        _publishError('No se pudo reenviar un mensaje recibido: $error');
      }
    }
  }

  Future<void> _connectTo(String endpointId) async {
    final nodeId = _myNodeId;
    if (nodeId == null || _connectingEndpoints.contains(endpointId)) return;

    _connectingEndpoints.add(endpointId);
    _updateState();
    _publish();

    final requested = await _service.requestConnection(nodeId, endpointId);
    if (!requested) {
      _connectingEndpoints.remove(endpointId);
      _updateState();
      _publish();
    }
  }

  void _updateState() {
    if (!_isSearching) {
      _state = 'idle';
    } else if (_connectedEndpoints.isNotEmpty) {
      _state = 'connected';
    } else if (_connectingEndpoints.isNotEmpty) {
      _state = 'connecting';
    } else {
      _state = 'searching';
    }
  }

  void _publish() {
    _publishState({
      'state': _state,
      'isSearching': _isSearching,
      'nodeId': _myNodeId,
      'errorMessage': _errorMessage,
      'discoveredEndpoints': [
        for (final endpoint in _discoveredEndpoints)
          {'endpointId': endpoint.endpointId, 'userName': endpoint.userName},
      ],
      'connectedEndpoints': _connectedEndpoints,
    });
  }
}
