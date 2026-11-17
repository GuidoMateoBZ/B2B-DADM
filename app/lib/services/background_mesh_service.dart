import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'mesh_controller.dart';
import 'mesh_protocol.dart';

const _notificationChannelId = 'mesh_service';
const _notificationId = 7021;
const _notificationTitle = 'B2B Mesh';

class BackgroundMeshService {
  BackgroundMeshService._() {
    _service.on(MeshEvent.serviceReady).listen((_) {
      _isReady = true;
      _readyCompleter?.complete();
      _readyCompleter = null;
    });
    _service.on(MeshEvent.serviceStopped).listen((_) {
      _isReady = false;
      _isStopping = true;
    });
  }

  static final BackgroundMeshService instance = BackgroundMeshService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isReady = false;
  bool _isStopping = false;
  Completer<void>? _readyCompleter;

  static const Duration _stopWaitTimeout = Duration(seconds: 5);
  static const Duration _stopPollInterval = Duration(milliseconds: 100);

  Stream<Map<String, dynamic>?> on(String event) => _service.on(event);

  Future<void> configure() async {
    const channel = AndroidNotificationChannel(
      _notificationChannelId,
      'Servicio de red mesh',
      description: 'Mantiene activa la conexión con la red mesh',
      importance: Importance.low,
    );
    final notifications = FlutterLocalNotificationsPlugin();
    await notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundMeshServiceEntryPoint,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        // `location` mantiene el acceso a la ubicación (requerido por el
        // discovery de Nearby) con la app cerrada; sin él falla con 8034.
        foregroundServiceTypes: const [
          AndroidForegroundType.connectedDevice,
          AndroidForegroundType.location,
        ],
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: _notificationTitle,
        initialNotificationContent: 'Red mesh activa',
        foregroundServiceNotificationId: _notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: backgroundMeshServiceEntryPoint,
      ),
    );
  }

  Future<bool> ensureRunning() async {
    if (_isStopping) await _waitUntilStopped();
    final running = await _service.isRunning();
    if (!running) {
      _isReady = false;
      _readyCompleter = Completer<void>();
      final started = await _service.startService();
      if (!started) return false;
    } else if (!_isReady) {
      _readyCompleter = Completer<void>();
      _service.invoke(MeshCommand.requestSnapshot);
    }

    try {
      if (!_isReady) {
        await _readyCompleter!.future.timeout(const Duration(seconds: 15));
      }
      return true;
    } on TimeoutException {
      _readyCompleter = null;
      return false;
    }
  }

  /// El servicio avisó que se detiene: se espera a que muera para no mandarle
  /// comandos que se perderían.
  Future<void> _waitUntilStopped() async {
    final deadline = DateTime.now().add(_stopWaitTimeout);
    while (await _service.isRunning() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_stopPollInterval);
    }
    _isStopping = false;
  }

  void invoke(String method, [Map<String, dynamic>? args]) {
    _service.invoke(method, args);
  }

  Future<bool> isRunning() => _service.isRunning();
}

@pragma('vm:entry-point')
void backgroundMeshServiceEntryPoint(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final controller = MeshController(
    emit: service.invoke,
    onNotificationText: (text) {
      if (service is AndroidServiceInstance) {
        unawaited(
          service.setForegroundNotificationInfo(
            title: _notificationTitle,
            content: text,
          ),
        );
      }
    },
  );

  String? str(Map<String, dynamic>? event, String key) =>
      event?[key] is String ? event![key] as String : null;

  service.on(MeshCommand.requestSnapshot).listen((_) {
    controller.emitSnapshot();
    service.invoke(MeshEvent.serviceReady);
  });
  service.on(MeshCommand.startSearch).listen((event) async {
    final nodeId = str(event, 'nodeId');
    if (nodeId == null) return;
    final uiState = event?['uiState'];
    await controller.startSearching(
      nodeId,
      uiPresence: uiState is Map ? UiPresence.fromMap(uiState) : null,
    );
  });
  service.on(MeshCommand.stopSearch).listen((_) async {
    final stopped = await controller.stopSearching();
    // Un start_search que llegó durante el cierre quedó encolado detrás:
    // en ese caso el servicio sigue vivo con la sesión nueva.
    if (stopped && controller.canStopService) {
      service.invoke(MeshEvent.serviceStopped);
      await service.stopSelf();
    }
  });
  service.on(MeshCommand.disconnectEndpoint).listen((event) async {
    final endpointId = str(event, 'endpointId');
    if (endpointId != null) await controller.disconnectEndpoint(endpointId);
  });
  service.on(MeshCommand.sendEnvelope).listen((event) async {
    final encoded = str(event, 'envelope');
    if (encoded != null) await controller.sendEnvelope(encoded);
  });
  service.on(MeshCommand.uiState).listen((event) {
    if (event != null) controller.updateUiPresence(UiPresence.fromMap(event));
  });

  await controller.initialize();
  controller.emitSnapshot();
  service.invoke(MeshEvent.serviceReady);
}
