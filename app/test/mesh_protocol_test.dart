import 'package:app/services/mesh_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MeshSnapshot', () {
    test('ida y vuelta por toMap/fromMap conserva todos los campos', () {
      const original = MeshSnapshot(
        state: NearbyState.connected,
        searching: true,
        myNodeId: 'a070a957-71cb',
        errorMessage: 'detalle',
        discovered: [(endpointId: 'E2', userName: 'nodo-2')],
        connected: {'E1': 'nodo-1'},
        connecting: ['E3'],
        stopping: true,
        stopFailed: true,
      );

      final copy = MeshSnapshot.fromMap(original.toMap());

      expect(copy.state, NearbyState.connected);
      expect(copy.searching, isTrue);
      expect(copy.myNodeId, 'a070a957-71cb');
      expect(copy.errorMessage, 'detalle');
      expect(copy.discovered, [(endpointId: 'E2', userName: 'nodo-2')]);
      expect(copy.connected, {'E1': 'nodo-1'});
      expect(copy.connecting, ['E3']);
      expect(copy.stopping, isTrue);
      expect(copy.stopFailed, isTrue);
    });

    test('un mapa vacío da valores por defecto y estado error', () {
      final snapshot = MeshSnapshot.fromMap({});
      expect(snapshot.state, NearbyState.error);
      expect(snapshot.searching, isFalse);
      expect(snapshot.myNodeId, isNull);
      expect(snapshot.discovered, isEmpty);
      expect(snapshot.connected, isEmpty);
      expect(snapshot.connecting, isEmpty);
      expect(snapshot.stopping, isFalse);
      expect(snapshot.stopFailed, isFalse);
    });

    test('descarta entradas con tipos inesperados sin lanzar', () {
      final snapshot = MeshSnapshot.fromMap({
        'state': 'inexistente',
        'searching': 'sí',
        'myNodeId': 42,
        'discovered': [
          {'endpointId': 'E1', 'userName': 'ok'},
          {'endpointId': 7, 'userName': 'mal'},
          'basura',
        ],
        'connected': {'E1': 'nodo', 2: 'mal', 'E3': null},
        'connecting': ['E4', 5, null],
        'stopping': 1,
      });

      expect(snapshot.state, NearbyState.error);
      expect(snapshot.searching, isFalse);
      expect(snapshot.myNodeId, isNull);
      expect(snapshot.discovered, [(endpointId: 'E1', userName: 'ok')]);
      expect(snapshot.connected, {'E1': 'nodo'});
      expect(snapshot.connecting, ['E4']);
      expect(snapshot.stopping, isFalse);
    });
  });

  group('UiPresence', () {
    test('ida y vuelta por toMap/fromMap', () {
      const presence = UiPresence(
        foreground: true,
        chatNodeId: 'nodo-1',
        broadcastVisible: true,
      );
      final copy = UiPresence.fromMap(presence.toMap());
      expect(copy.foreground, isTrue);
      expect(copy.chatNodeId, 'nodo-1');
      expect(copy.broadcastVisible, isTrue);
    });

    test('valores ausentes o inválidos equivalen a UI no visible', () {
      final copy = UiPresence.fromMap({'foreground': 'true', 'chatNodeId': 3});
      expect(copy.foreground, isFalse);
      expect(copy.chatNodeId, isNull);
      expect(copy.broadcastVisible, isFalse);
    });
  });
}
