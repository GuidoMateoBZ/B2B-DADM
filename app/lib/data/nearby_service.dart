import 'dart:convert';
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';

/// Wrapper sobre la API de Nearby Connections.
/// Ningún otro archivo del proyecto importa `package:nearby_connections` directamente.
class NearbyService {
  static const String serviceId = 'com.b2b.dadm';
  static const Strategy strategy = Strategy.P2P_CLUSTER;

  final Nearby _nearby = Nearby();

  // ── Callbacks que el Provider debe asignar ──

  /// Se invoca cuando se descubre un nuevo endpoint cercano.
  void Function(String endpointId, String userName)? onEndpointFound;

  /// Se invoca cuando un endpoint descubierto deja de estar disponible.
  void Function(String endpointId)? onEndpointLost;

  /// Se invoca cuando un endpoint remoto solicita o inicia una conexión.
  /// [endpointId] es el ID del peer, [info] contiene datos de la conexión.
  void Function(String endpointId, ConnectionInfo info)? onConnectionInitiated;

  /// Se invoca con el resultado de una solicitud de conexión.
  void Function(String endpointId, Status status)? onConnectionResult;

  /// Se invoca cuando un endpoint conectado se desconecta.
  void Function(String endpointId)? onDisconnected;

  /// Se invoca cuando se recibe un mensaje de texto de un endpoint conectado.
  void Function(String endpointId, String message)? onMessageReceived;

  // ── Advertising ──

  /// Comienza a anunciar este dispositivo para que otros lo descubran.
  /// [userName] es el nombre visible (usamos el Node ID).
  Future<bool> startAdvertising(String userName) async {
    try {
      return await _nearby.startAdvertising(
        userName,
        strategy,
        onConnectionInitiated: _handleConnectionInitiated,
        onConnectionResult: _handleConnectionResult,
        onDisconnected: _handleDisconnected,
        serviceId: serviceId,
      );
    } catch (e) {
      return false;
    }
  }

  /// Detiene el advertising.
  Future<void> stopAdvertising() async {
    try {
      await _nearby.stopAdvertising();
    } catch (_) {}
  }

  // ── Discovery ──

  /// Comienza a buscar dispositivos cercanos que estén haciendo advertising.
  Future<bool> startDiscovery(String userName) async {
    try {
      return await _nearby.startDiscovery(
        userName,
        strategy,
        onEndpointFound: (String endpointId, String userName, String serviceId) {
          onEndpointFound?.call(endpointId, userName);
        },
        onEndpointLost: (String? endpointId) {
          if (endpointId != null) {
            onEndpointLost?.call(endpointId);
          }
        },
        serviceId: serviceId,
      );
    } catch (e) {
      return false;
    }
  }

  /// Detiene la búsqueda de dispositivos.
  Future<void> stopDiscovery() async {
    try {
      await _nearby.stopDiscovery();
    } catch (_) {}
  }

  // ── Conexión ──

  /// Solicita conexión a un endpoint descubierto.
  /// [userName] es el nombre de este dispositivo (Node ID).
  Future<bool> requestConnection(String userName, String endpointId) async {
    try {
      return await _nearby.requestConnection(
        userName,
        endpointId,
        onConnectionInitiated: _handleConnectionInitiated,
        onConnectionResult: _handleConnectionResult,
        onDisconnected: _handleDisconnected,
      );
    } catch (e) {
      return false;
    }
  }

  /// Acepta una conexión entrante y registra los callbacks de recepción de datos.
  Future<bool> acceptConnection(String endpointId) async {
    try {
      return await _nearby.acceptConnection(
        endpointId,
        onPayLoadRecieved: (String endpointId, Payload payload) {
          if (payload.type == PayloadType.BYTES && payload.bytes != null) {
            final message = utf8.decode(payload.bytes!);
            onMessageReceived?.call(endpointId, message);
          }
        },
        onPayloadTransferUpdate: (String endpointId, PayloadTransferUpdate update) {
          // Por ahora solo enviamos bytes (texto), no necesitamos tracking de progreso.
        },
      );
    } catch (e) {
      return false;
    }
  }

  // ── Envío de mensajes ──

  /// Envía un mensaje de texto a un endpoint conectado.
  Future<void> sendMessage(String endpointId, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    try {
      await _nearby.sendBytesPayload(endpointId, bytes);
    } catch (_) {}
  }

  // ── Desconexión ──

  /// Se desconecta de un endpoint específico.
  Future<void> disconnectFromEndpoint(String endpointId) async {
    try {
      await _nearby.disconnectFromEndpoint(endpointId);
    } catch (_) {}
  }

  /// Detiene todas las conexiones, advertising y discovery.
  Future<void> stopAll() async {
    try {
      await _nearby.stopAllEndpoints();
    } catch (_) {}
  }

  // ── Handlers internos ──

  void _handleConnectionInitiated(String endpointId, ConnectionInfo info) {
    onConnectionInitiated?.call(endpointId, info);
  }

  void _handleConnectionResult(String endpointId, Status status) {
    onConnectionResult?.call(endpointId, status);
  }

  void _handleDisconnected(String endpointId) {
    onDisconnected?.call(endpointId);
  }
}
