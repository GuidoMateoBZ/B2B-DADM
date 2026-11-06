import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../providers/nearby_provider.dart';

const _notificationChannelId = 'mesh_service';
const _notificationId = 7021;

class BackgroundMeshService {
  BackgroundMeshService._() {
    _service.on('service_ready').listen((_) {
      _isReady = true;
      _readyCompleter?.complete();
      _readyCompleter = null;
    });
  }

  static final BackgroundMeshService instance = BackgroundMeshService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isReady = false;
  Completer<void>? _readyCompleter;

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
        foregroundServiceTypes: const [AndroidForegroundType.connectedDevice],
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'B2B Mesh',
        initialNotificationContent: 'Preparando conexión segura',
        foregroundServiceNotificationId: _notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: backgroundMeshServiceEntryPoint,
      ),
    );
  }

  Future<bool> ensureRunning() async {
    final running = await _service.isRunning();
    if (!running) {
      _isReady = false;
      _readyCompleter = Completer<void>();
      final started = await _service.startService();
      if (!started) return false;
    } else if (!_isReady) {
      _readyCompleter = Completer<void>();
      _service.invoke('request_snapshot');
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

  void invoke(String method, [Map<String, dynamic>? args]) {
    _service.invoke(method, args);
  }

  Future<bool> isRunning() => _service.isRunning();
}

@pragma('vm:entry-point')
void backgroundMeshServiceEntryPoint(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final controller = NearbyProvider.backgroundController();
  controller.setServiceEmitter(service.invoke);
  controller.addListener(controller.emitServiceSnapshot);

  service.on('request_snapshot').listen((_) {
    controller.emitServiceSnapshot();
    service.invoke('service_ready');
  });
  service.on('start_search').listen((event) async {
    if (event == null) return;
    await controller.startSearchingInBackground(
      event['nodeId'] as String,
      event['media'] as Map<dynamic, dynamic>?,
      event['uiState'] as Map<dynamic, dynamic>?,
    );
  });
  service.on('stop_search').listen((_) async {
    final stopped = await controller.stopSearchingInBackground();
    if (stopped) {
      await service.stopSelf();
    }
  });
  service.on('disconnect_endpoint').listen((event) async {
    final endpointId = event?['endpointId'] as String?;
    if (endpointId != null) {
      await controller.disconnectEndpointInBackground(endpointId);
    }
  });
  service.on('send_envelope').listen((event) async {
    final encoded = event?['envelope'] as String?;
    if (encoded != null) {
      await controller.sendEnvelopeInBackground(encoded);
    }
  });
  service.on('media_state').listen((event) {
    if (event != null) controller.applyMediaStateInBackground(event);
  });
  service.on('ui_state').listen((event) {
    if (event != null) controller.updateUiPresence(event);
  });

  await controller.initializeBackgroundController();
  controller.emitServiceSnapshot();
  service.invoke('service_ready');
}
