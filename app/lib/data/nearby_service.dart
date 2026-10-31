import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Resultado de una solicitud de conexión a un endpoint.
enum ConnectionRequestResult { requested, alreadyConnected, failed }

/// Error de [NearbyService.stopAll]: indica qué llamadas fallaron.
class NearbyStopException implements Exception {
  final List<String> failures;
  NearbyStopException(this.failures);

  @override
  String toString() => 'NearbyStopException: ${failures.join(' | ')}';
}

/// Wrapper sobre la API de Nearby Connections.
/// Ningún otro archivo del proyecto importa `package:nearby_connections` directamente.
class NearbyService {
  static const String serviceId = 'com.b2b.dadm';
  static const Strategy strategy = Strategy.P2P_CLUSTER;

  /// Pausa entre detener y volver a iniciar discovery/advertising (evita 8001/8002).
  static const Duration restartPause = Duration(milliseconds: 500);

  static const int statusAlreadyAdvertising = 8001;
  static const int statusAlreadyDiscovering = 8002;
  static const int statusAlreadyConnected = 8003;

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

  /// Último mensaje de error capturado en operaciones nativas.
  String? lastError;

  /// Código numérico de Nearby (ej. 8002) del último error, si se pudo extraer.
  int? lastErrorCode;

  /// El plugin reporta siempre `PlatformException.code == "Failure"`; el código
  /// de Nearby viene al inicio del mensaje ("8002: STATUS_ALREADY_DISCOVERING").
  static int? parseStatusCode(Object error) {
    if (error is! PlatformException) return null;
    final match = RegExp(r'^\s*(\d+):').firstMatch(error.message ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  // ── Advertising ──

  /// Comienza a anunciar este dispositivo para que otros lo descubran.
  /// [userName] es el nombre visible (usamos el Node ID).
  Future<bool> startAdvertising(String userName) async {
    lastError = null;
    lastErrorCode = null;
    try {
      final success = await _nearby.startAdvertising(
        userName,
        strategy,
        onConnectionInitiated: _handleConnectionInitiated,
        onConnectionResult: _handleConnectionResult,
        onDisconnected: _handleDisconnected,
        serviceId: serviceId,
      );
      debugPrint('[NearbyService] startAdvertising retorno: $success');
      if (!success && lastError == null) {
        lastError = 'Google Play Services rechazó startAdvertising (retornó false).';
      }
      return success;
    } catch (e, stack) {
      final code = parseStatusCode(e);
      if (code == statusAlreadyAdvertising) {
        debugPrint('[NearbyService] startAdvertising: ya estaba activo (8001)');
        return true;
      }
      lastErrorCode = code;
      lastError = 'startAdvertising error: $e';
      debugPrint('[NearbyService] Excepción en startAdvertising: $e\n$stack');
      return false;
    }
  }

  /// Reinicia solo el advertising. No toca los enlaces existentes.
  Future<bool> restartAdvertising(String userName) async {
    await stopAdvertising();
    await Future<void>.delayed(restartPause);
    return startAdvertising(userName);
  }

  /// Detiene el advertising.
  Future<void> stopAdvertising() async {
    try {
      await _nearby.stopAdvertising();
    } catch (e) {
      debugPrint('[NearbyService] Error en stopAdvertising: $e');
    }
  }

  // ── Discovery ──

  /// Comienza a buscar dispositivos cercanos que estén haciendo advertising.
  Future<bool> startDiscovery(String userName) async {
    try {
      final success = await _nearby.startDiscovery(
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
      debugPrint('[NearbyService] startDiscovery retorno: $success');
      if (!success) {
        final msg = 'Google Play Services rechazó startDiscovery (retornó false).';
        lastError = (lastError != null) ? '$lastError | $msg' : msg;
      }
      return success;
    } catch (e, stack) {
      final code = parseStatusCode(e);
      if (code == statusAlreadyDiscovering) {
        debugPrint('[NearbyService] startDiscovery: ya estaba activo (8002)');
        return true;
      }
      lastErrorCode = code;
      final msg = 'startDiscovery error: $e';
      lastError = (lastError != null) ? '$lastError | $msg' : msg;
      debugPrint('[NearbyService] Excepción en startDiscovery: $e\n$stack');
      return false;
    }
  }

  /// Detiene la búsqueda de dispositivos.
  Future<void> stopDiscovery() async {
    try {
      await _nearby.stopDiscovery();
    } catch (_) {}
  }

  /// Reinicia solo el discovery para que Nearby vuelva a emitir `onEndpointFound`
  /// de todos los pares visibles. No toca los enlaces existentes.
  Future<bool> restartDiscovery(String userName) async {
    await stopDiscovery();
    await Future<void>.delayed(restartPause);
    return startDiscovery(userName);
  }

  // ── Conexión ──

  /// Solicita conexión a un endpoint descubierto.
  /// [userName] es el nombre de este dispositivo (Node ID).
  Future<ConnectionRequestResult> requestConnection(
    String userName,
    String endpointId,
  ) async {
    try {
      final ok = await _nearby.requestConnection(
        userName,
        endpointId,
        onConnectionInitiated: _handleConnectionInitiated,
        onConnectionResult: _handleConnectionResult,
        onDisconnected: _handleDisconnected,
      );
      return ok ? ConnectionRequestResult.requested : ConnectionRequestResult.failed;
    } catch (e) {
      final code = parseStatusCode(e);
      lastErrorCode = code;
      lastError = 'requestConnection error: $e';
      debugPrint('[NearbyService] requestConnection a $endpointId: $e');
      return code == statusAlreadyConnected
          ? ConnectionRequestResult.alreadyConnected
          : ConnectionRequestResult.failed;
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
          // Solo se envían bytes (texto): no hay tracking de progreso, pero un
          // fallo es el único indicio de una conexión fantasma (el plugin no
          // reporta errores de sendPayload).
          if (update.status == PayloadStatus.FAILURE ||
              update.status == PayloadStatus.CANCELED) {
            debugPrint(
              '[NearbyService] Transferencia ${update.status.name} con $endpointId (payload ${update.id})',
            );
          }
        },
      );
    } catch (e) {
      lastErrorCode = parseStatusCode(e);
      lastError = 'acceptConnection error: $e';
      debugPrint('[NearbyService] acceptConnection de $endpointId: $e');
      return false;
    }
  }

  /// Rechaza una conexión entrante (ej. de un nodo bloqueado).
  Future<bool> rejectConnection(String endpointId) async {
    try {
      return await _nearby.rejectConnection(endpointId);
    } catch (e) {
      lastErrorCode = parseStatusCode(e);
      lastError = 'rejectConnection error: $e';
      debugPrint('[NearbyService] rejectConnection de $endpointId: $e');
      return false;
    }
  }

  // ── Envío de mensajes ──

  /// Envía un mensaje de texto (o JSON) a un endpoint conectado.
  Future<void> sendMessage(String endpointId, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    try {
      await _nearby.sendBytesPayload(endpointId, bytes);
    } catch (e) {
      debugPrint('[NearbyService] Error enviando a $endpointId: $e');
    }
  }

  /// Envía un mensaje de texto (o JSON) a múltiples endpoints conectados.
  Future<void> sendToEndpoints(List<String> endpointIds, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    for (final endpointId in endpointIds) {
      try {
        await _nearby.sendBytesPayload(endpointId, bytes);
      } catch (e) {
        debugPrint('[NearbyService] Error enviando a $endpointId: $e');
      }
    }
  }

  // ── Desconexión ──

  /// Se desconecta de un endpoint específico.
  Future<void> disconnectFromEndpoint(String endpointId) async {
    try {
      await _nearby.disconnectFromEndpoint(endpointId);
    } catch (_) {}
  }

  /// Detiene todas las conexiones, advertising y discovery.
  /// Ejecuta siempre las tres llamadas; si alguna falla, al final lanza un
  /// único [NearbyStopException] que indica cuáles.
  Future<void> stopAll() async {
    final failures = <String>[];
    Future<void> attempt(String name, Future<void> Function() call) async {
      try {
        await call();
      } catch (e) {
        failures.add('$name: $e');
      }
    }

    await attempt('stopAllEndpoints', _nearby.stopAllEndpoints);
    await attempt('stopAdvertising', _nearby.stopAdvertising);
    await attempt('stopDiscovery', _nearby.stopDiscovery);

    if (failures.isNotEmpty) throw NearbyStopException(failures);
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
