import 'package:app/data/models/envelope.dart';
import 'package:app/services/message_relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageRelay Routing & Deduplication Tests', () {
    late MessageRelay relay;

    setUp(() {
      relay = MessageRelay(myNodeId: 'node-B');
      relay.addNeighbor('endpoint-A', 'node-A');
      relay.addNeighbor('endpoint-C', 'node-C');
    });

    test('Chat 1-a-1: Delivers when toNodeId matches myNodeId', () {
      final envelope = Envelope(
        messageId: 'msg-for-b',
        fromNodeId: 'node-A',
        toNodeId: 'node-B',
        text: 'Hola B, soy A',
        ttl: 3,
        timestamp: 1000,
      );

      final result = relay.processIncoming('endpoint-A', envelope);

      expect(result.action, RelayAction.deliver);
      expect(result.forwardTo, isEmpty);
    });

    test('Chat 1-a-1: Forwards directly to destination if neighbor', () {
      // Mensaje de A para C, pasando por B
      final envelope = Envelope(
        messageId: 'msg-for-c',
        fromNodeId: 'node-A',
        toNodeId: 'node-C',
        text: 'Hola C, soy A via B',
        ttl: 3,
        timestamp: 1000,
      );

      final result = relay.processIncoming('endpoint-A', envelope);

      expect(result.action, RelayAction.forward);
      expect(result.forwardTo, equals(['endpoint-C']));
      expect(result.envelope.ttl, 2); // TTL decrementado
    });

    test('Chat 1-a-1: Floods to all neighbors except sender when destination not direct', () {
      // Mensaje de A para D (D no es vecino directo de B)
      final envelope = Envelope(
        messageId: 'msg-for-d',
        fromNodeId: 'node-A',
        toNodeId: 'node-D',
        text: 'Buscando a D',
        ttl: 3,
        timestamp: 1000,
      );

      final result = relay.processIncoming('endpoint-A', envelope);

      expect(result.action, RelayAction.forward);
      // Debe reenviar a C pero NO a A (de donde vino)
      expect(result.forwardTo, equals(['endpoint-C']));
      expect(result.envelope.ttl, 2);
    });

    test('Deduplication: Discards previously seen messages', () {
      final envelope = Envelope(
        messageId: 'msg-duplicate',
        fromNodeId: 'node-A',
        toNodeId: 'node-B',
        text: 'Mensaje repetido',
        ttl: 3,
        timestamp: 1000,
      );

      final first = relay.processIncoming('endpoint-A', envelope);
      expect(first.action, RelayAction.deliver);

      // Mismo mensaje llegando por segunda vez (por ejemplo rebotado)
      final second = relay.processIncoming('endpoint-C', envelope);
      expect(second.action, RelayAction.discard);
    });

    test('TTL Expiration: Discards message when TTL <= 0 and not for me', () {
      final envelope = Envelope(
        messageId: 'msg-expired',
        fromNodeId: 'node-A',
        toNodeId: 'node-Z',
        text: 'Mensaje sin saltos restantes',
        ttl: 0,
        timestamp: 1000,
      );

      final result = relay.processIncoming('endpoint-A', envelope);
      expect(result.action, RelayAction.discard);
    });

    test('Broadcast SOS: Delivers and forwards to all other neighbors with TTL - 1', () {
      final envelope = Envelope(
        messageId: 'sos-999',
        fromNodeId: 'node-A',
        toNodeId: Envelope.broadcastAddress,
        text: 'Alerta SOS general',
        ttl: 3,
        timestamp: 1000,
      );

      final result = relay.processIncoming('endpoint-A', envelope);

      expect(result.action, RelayAction.deliver);
      expect(result.forwardTo, equals(['endpoint-C']));
      expect(result.envelope.ttl, 2);
    });

    test('Broadcast SOS: Delivers but does not forward when TTL reaches 0', () {
      final envelope = Envelope(
        messageId: 'sos-last-hop',
        fromNodeId: 'node-A',
        toNodeId: Envelope.broadcastAddress,
        text: 'Último salto de SOS',
        ttl: 0,
        timestamp: 1000,
      );

      final result = relay.processIncoming('endpoint-A', envelope);

      expect(result.action, RelayAction.deliver);
      expect(result.forwardTo, isEmpty);
    });

    test('getTargetEndpoints for outgoing message marks message as seen and finds route', () {
      final envelope = Envelope.create(
        fromNodeId: 'node-B',
        toNodeId: 'node-C',
        text: 'Mensaje mío para C',
      );

      final targets = relay.getTargetEndpoints(envelope);

      expect(targets, equals(['endpoint-C']));

      // Si nos vuelve el mismo mensaje, debe descartarse
      final reimport = relay.processIncoming('endpoint-A', envelope);
      expect(reimport.action, RelayAction.discard);
    });
  });
}
