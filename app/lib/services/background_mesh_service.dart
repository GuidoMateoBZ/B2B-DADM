import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/message_repository.dart';
import 'local_notification_service.dart';
import 'mesh_network_controller.dart';

const _activeNodeIdKey = 'active_mesh_node_id';
const _meshNotificationChannelId = 'b2b_mesh_service';

class BackgroundMeshService {
  BackgroundMeshService._() {
    _service.on('service_ready').listen((_) {
      final completer = _pendingReady;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    });
  }

  static final BackgroundMeshService instance = BackgroundMeshService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  Completer<void>? _pendingReady;

  Stream<Map<String, dynamic>?> get states => _service.on('mesh_state');
  Stream<Map<String, dynamic>?> get messageChanges =>
      _service.on('message_changed');
  Stream<Map<String, dynamic>?> get errors => _service.on('mesh_error');

  Future<void> configure() async {
    if (!Platform.isAndroid) return;

    final configured = await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundMeshServiceEntrypoint,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _meshNotificationChannelId,
        initialNotificationTitle: 'B2B Mesh',
        initialNotificationContent: 'Iniciando conexión Nearby',
        foregroundServiceNotificationId: 7301,
        foregroundServiceTypes: const [AndroidForegroundType.connectedDevice],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: backgroundMeshServiceEntrypoint,
      ),
    );
    if (!configured) {
      throw StateError('No se pudo configurar flutter_background_service.');
    }
  }

  Future<void> start(String nodeId) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'El servicio mesh en segundo plano requiere Android.',
      );
    }

    if (await _service.isRunning()) {
      _service.invoke('start_mesh', {'nodeId': nodeId});
      return;
    }

    final ready = Completer<void>();
    _pendingReady = ready;
    final started = await _service.startService();
    if (!started) {
      _pendingReady = null;
      throw StateError('Android no pudo iniciar el servicio mesh.');
    }

    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StateError('El servicio mesh no confirmó su inicio a tiempo.');
    } finally {
      if (identical(_pendingReady, ready)) {
        _pendingReady = null;
      }
    }

    _service.invoke('start_mesh', {'nodeId': nodeId});
  }

  Future<bool> isRunning() => _service.isRunning();

  void requestCurrentState() => _service.invoke('get_mesh_state');

  void stop() => _service.invoke('stop_mesh');

  void disconnectEndpoint(String endpointId) =>
      _service.invoke('disconnect_endpoint', {'endpointId': endpointId});

  void connectTo(String endpointId) =>
      _service.invoke('connect_endpoint', {'endpointId': endpointId});

  void sendEnvelope(String encodedEnvelope) =>
      _service.invoke('send_envelope', {'envelope': encodedEnvelope});
}

@pragma('vm:entry-point')
Future<void> backgroundMeshServiceEntrypoint(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  await localNotificationService.initializeForBackground();
  final preferences = await SharedPreferences.getInstance();
  await preferences.reload();

  final controller = MeshNetworkController(
    repository: MessageRepository(),
    publishState: (state) => service.invoke('mesh_state', state),
    publishMessageChange: (receiverId) =>
        service.invoke('message_changed', {'receiverId': receiverId}),
    publishError: (message) =>
        service.invoke('mesh_error', {'message': message}),
  );

  service.on('start_mesh').listen((event) async {
    final nodeId = event?['nodeId'] as String?;
    if (nodeId == null || nodeId.trim().isEmpty) {
      service.invoke('mesh_error', {
        'message': 'No se recibió un Node ID válido.',
      });
      return;
    }

    try {
      await preferences.setString(_activeNodeIdKey, nodeId);
      final started = await controller.start(nodeId);
      if (!started) {
        await preferences.remove(_activeNodeIdKey);
        await service.stopSelf();
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[BackgroundMeshService] Error iniciando mesh: $error\n$stackTrace',
      );
      await preferences.remove(_activeNodeIdKey);
      service.invoke('mesh_error', {
        'message': 'No se pudo iniciar Nearby: $error',
      });
      await service.stopSelf();
    }
  });

  service.on('stop_mesh').listen((_) async {
    try {
      await preferences.remove(_activeNodeIdKey);
      await controller.stop();
      await service.stopSelf();
    } catch (error, stackTrace) {
      debugPrint(
        '[BackgroundMeshService] Error deteniendo mesh: $error\n$stackTrace',
      );
      service.invoke('mesh_error', {
        'message': 'No se pudo detener Nearby: $error',
      });
    }
  });

  service.on('get_mesh_state').listen((_) {
    controller.publishCurrentState();
  });

  service.on('disconnect_endpoint').listen((event) async {
    final endpointId = event?['endpointId'] as String?;
    if (endpointId == null) return;
    await controller.disconnectEndpoint(endpointId);
  });

  service.on('connect_endpoint').listen((event) async {
    final endpointId = event?['endpointId'] as String?;
    if (endpointId == null) return;
    await controller.connectTo(endpointId);
  });

  service.on('send_envelope').listen((event) async {
    final envelope = event?['envelope'] as String?;
    if (envelope == null) return;
    await controller.sendEnvelope(envelope);
  });

  service.invoke('service_ready');

  final activeNodeId = preferences.getString(_activeNodeIdKey);
  if (activeNodeId != null && activeNodeId.isNotEmpty) {
    try {
      final started = await controller.start(activeNodeId);
      if (!started) {
        await preferences.remove(_activeNodeIdKey);
        await service.stopSelf();
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[BackgroundMeshService] Error restaurando mesh: $error\n$stackTrace',
      );
      await preferences.remove(_activeNodeIdKey);
      service.invoke('mesh_error', {
        'message': 'No se pudo restaurar Nearby: $error',
      });
      await service.stopSelf();
    }
  } else {
    controller.publishCurrentState();
  }
}
