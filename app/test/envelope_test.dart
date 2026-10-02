import 'package:app/data/models/envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Envelope Model Tests', () {
    test('Envelope.create creates valid 1-to-1 envelope with default TTL', () {
      final envelope = Envelope.create(
        fromNodeId: 'node-A',
        toNodeId: 'node-B',
        text: 'Hola nodo B',
      );

      expect(envelope.messageId.isNotEmpty, isTrue);
      expect(envelope.fromNodeId, 'node-A');
      expect(envelope.toNodeId, 'node-B');
      expect(envelope.text, 'Hola nodo B');
      expect(envelope.ttl, Envelope.defaultTtl);
      expect(envelope.isBroadcast, isFalse);
      expect(envelope.timestamp > 0, isTrue);
    });

    test('Envelope.create creates valid broadcast envelope', () {
      final envelope = Envelope.create(
        fromNodeId: 'node-A',
        toNodeId: Envelope.broadcastAddress,
        text: 'Emergencia SOS',
      );

      expect(envelope.toNodeId, 'all');
      expect(envelope.isBroadcast, isTrue);
    });

    test('decrementTtl decrements TTL by 1 while preserving fields', () {
      final original = Envelope(
        messageId: 'msg-123',
        fromNodeId: 'node-A',
        toNodeId: 'node-C',
        text: 'Mensaje multi-hop',
        ttl: 3,
        timestamp: 1700000000,
      );

      final forwarded = original.decrementTtl();

      expect(forwarded.messageId, original.messageId);
      expect(forwarded.fromNodeId, original.fromNodeId);
      expect(forwarded.toNodeId, original.toNodeId);
      expect(forwarded.text, original.text);
      expect(forwarded.ttl, 2);
      expect(forwarded.timestamp, original.timestamp);
    });

    test('encode and decode roundtrip maintains all fields', () {
      final original = Envelope(
        messageId: 'unique-id-999',
        fromNodeId: 'origin-node',
        toNodeId: 'destination-node',
        text: 'Probando serialización JSON',
        ttl: 2,
        timestamp: 1705000000,
      );

      final encoded = original.encode();
      final decoded = Envelope.decode(encoded);

      expect(decoded.messageId, original.messageId);
      expect(decoded.fromNodeId, original.fromNodeId);
      expect(decoded.toNodeId, original.toNodeId);
      expect(decoded.text, original.text);
      expect(decoded.ttl, original.ttl);
      expect(decoded.timestamp, original.timestamp);
      expect(decoded.isBroadcast, isFalse);
    });
  });
}
