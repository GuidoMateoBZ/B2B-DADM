import 'dart:async';

import 'package:app/data/models/media_state.dart';
import 'package:app/data/nearby_service.dart';
import 'package:app/services/media_state_service.dart';
import 'package:app/services/mesh_controller.dart';
import 'package:app/services/mesh_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _allOn = MediaState(
  bluetooth: RadioState.on,
  wifi: RadioState.on,
  location: true,
  airplane: false,
);

/// Nearby sin plataforma: registra llamadas y deja simular callbacks.
class FakeNearbyService extends NearbyService {
  int advertisingStarts = 0;
  int stopAllCalls = 0;

  /// Se ejecuta dentro de `stopAll` (por ejemplo, para emitir `onDisconnected`).
  void Function()? onStopAll;

  @override
  Future<bool> startAdvertising(String userName) async {
    advertisingStarts++;
    return true;
  }

  @override
  Future<bool> startDiscovery(String userName) async => true;

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<bool> restartAdvertising(String userName) async => true;

  @override
  Future<bool> restartDiscovery(String userName) async => true;

  @override
  Future<ConnectionRequestResult> requestConnection(
    String userName,
    String endpointId,
  ) async => ConnectionRequestResult.requested;

  @override
  Future<bool> acceptConnection(String endpointId) async => true;

  @override
  Future<bool> rejectConnection(String endpointId) async => true;

  @override
  Future<void> sendToEndpoints(List<String> endpointIds, String text) async {}

  @override
  Future<void> disconnectFromEndpoint(String endpointId) async {}

  @override
  Future<void> stopAll() async {
    stopAllCalls++;
    onStopAll?.call();
  }

  /// Simula un enlace entrante ya establecido.
  void connectPeer(String endpointId, String nodeId) {
    onConnectionInitiated!(endpointId, ConnectionInfo(nodeId, 'tok', true));
    onConnectionResult!(endpointId, Status.CONNECTED);
  }
}

class FakeMediaStateService extends MediaStateService {
  final _controller = StreamController<MediaState>.broadcast();

  @override
  Stream<MediaState> get stream => _controller.stream;

  @override
  Future<MediaState?> current() async => _allOn;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNearbyService nearby;
  late MeshController controller;
  late List<Map<String, dynamic>> snapshots;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nearby = FakeNearbyService();
    snapshots = [];
    controller = MeshController(
      emit: (event, [data]) {
        if (event == MeshEvent.snapshot) snapshots.add(data!);
      },
      nearby: nearby,
      mediaService: FakeMediaStateService(),
      stopDisconnectionTimeout: const Duration(milliseconds: 200),
      stopDrainPeriod: const Duration(milliseconds: 10),
    );
  });

  tearDown(() => controller.dispose());

  Future<void> startSession() async {
    await controller.startSearching('nodo-a', initialMedia: _allOn);
    expect(controller.isSearching, isTrue);
  }

  group('cierre', () {
    test('con un enlace activo espera su onDisconnected', () async {
      await startSession();
      nearby.connectPeer('E1', 'nodo-b');
      expect(controller.connectedCount, 1);

      var disconnectedAt = -1;
      final clock = Stopwatch()..start();
      final fake = nearby;
      fake.onStopAll = () {
        // Una sola vez: el dispose() del tearDown vuelve a llamar a stopAll.
        fake.onStopAll = null;
        Timer(const Duration(milliseconds: 50), () {
          disconnectedAt = clock.elapsedMilliseconds;
          fake.onDisconnected!('E1');
        });
      };

      final stopped = await controller.stopSearching();

      expect(stopped, isTrue);
      // Si el cierre no esperara, el timer de 50 ms todavía no habría corrido.
      expect(disconnectedAt, greaterThanOrEqualTo(50));
      expect(controller.state, NearbyState.idle);
      expect(controller.connectedCount, 0);
      expect(controller.stopFailed, isFalse);
      expect(controller.snapshot.stopping, isTrue);
      expect(controller.canStopService, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(MeshController.activeSessionKey), isFalse);
    });

    test('sin onDisconnected vence la espera y queda en error', () async {
      await startSession();
      nearby.connectPeer('E1', 'nodo-b');

      final stopped = await controller.stopSearching();

      expect(stopped, isFalse);
      expect(controller.state, NearbyState.error);
      expect(controller.stopFailed, isTrue);
      expect(controller.errorMessage, isNotNull);
      expect(controller.snapshot.stopping, isFalse);
    });

    test('el primer snapshot del cierre ya avisa stopping', () async {
      await startSession();
      snapshots.clear();

      final stop = controller.stopSearching();
      expect(snapshots, isNotEmpty);
      expect(MeshSnapshot.fromMap(snapshots.first).stopping, isTrue);
      await stop;
    });

    test('sin enlaces se confirma sin esperar desconexiones', () async {
      await startSession();
      expect(await controller.stopSearching(), isTrue);
      expect(nearby.stopAllCalls, greaterThanOrEqualTo(1));
    });
  });

  group('carrera Desconectar → Conectar', () {
    test(
      'un start_search durante el cierre impide detener el servicio',
      () async {
        await startSession();
        expect(nearby.advertisingStarts, 1);

        final stop = controller.stopSearching();
        final start = controller.startSearching('nodo-a', initialMedia: _allOn);

        final stopped = await stop;
        // Cuando el handler de stop_search decide, el inicio sigue encolado.
        expect(stopped, isTrue);
        expect(controller.hasPendingStart, isTrue);
        expect(controller.canStopService, isFalse);

        await start;
        expect(controller.isSearching, isTrue);
        expect(controller.hasPendingStart, isFalse);
        expect(controller.snapshot.stopping, isFalse);
        expect(controller.state, NearbyState.searching);
        expect(nearby.advertisingStarts, 2);
      },
    );

    test('start_search con la sesión activa se ignora', () async {
      await startSession();
      await controller.startSearching('nodo-a', initialMedia: _allOn);
      expect(nearby.advertisingStarts, 1);
    });
  });

  group('texto de la notificación', () {
    String text(
      NearbyState state, {
      int connected = 0,
      bool stopping = false,
    }) => MeshController.notificationText(
      MeshSnapshot(
        state: state,
        connected: {for (var i = 0; i < connected; i++) 'E$i': 'nodo-$i'},
        stopping: stopping,
      ),
    );

    test('describe cada estado', () {
      expect(text(NearbyState.searching), 'Red mesh activa · buscando vecinos');
      expect(
        text(NearbyState.connecting),
        'Red mesh activa · conectando con un vecino',
      );
      expect(
        text(NearbyState.connected, connected: 1),
        'Red mesh activa · 1 vecino conectado',
      );
      expect(
        text(NearbyState.connected, connected: 3),
        'Red mesh activa · 3 vecinos conectados',
      );
      expect(
        text(NearbyState.noMedia),
        'Red mesh en pausa · activá el Bluetooth',
      );
      expect(
        text(NearbyState.noLocation),
        'Red mesh activa · sin ubicación, no busca vecinos nuevos',
      );
      expect(text(NearbyState.error), 'Red mesh con error · abrí la app');
      expect(text(NearbyState.idle), 'Red mesh detenida');
      expect(
        text(NearbyState.searching, stopping: true),
        'Desconectando la red mesh',
      );
    });

    test('con vecinos conectados manda la cantidad', () {
      expect(
        text(NearbyState.connecting, connected: 2),
        'Red mesh activa · 2 vecinos conectados',
      );
      expect(
        text(NearbyState.noLocation, connected: 1),
        'Red mesh activa · 1 vecino conectado',
      );
    });

    test('solo se actualiza cuando cambia el texto', () async {
      final texts = <String>[];
      final c = MeshController(
        onNotificationText: texts.add,
        nearby: FakeNearbyService(),
        mediaService: FakeMediaStateService(),
      );
      addTearDown(c.dispose);

      await c.startSearching('nodo-a', initialMedia: _allOn);
      c.emitSnapshot();
      c.emitSnapshot();

      expect(texts, ['Red mesh activa · buscando vecinos']);
    });
  });
}
