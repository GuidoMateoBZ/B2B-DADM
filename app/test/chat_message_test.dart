import 'package:app/data/models/chat_message.dart';
import 'package:app/data/models/envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatMessage Model Tests', () {
    test('fromEnvelope maps correctly when message is mine', () {
      final envelope = Envelope(
        messageId: 'msg-1',
        fromNodeId: 'my-node',
        toNodeId: 'peer-node',
        text: 'Hola peer',
        ttl: 3,
        timestamp: 1710000000,
      );

      final msg = ChatMessage.fromEnvelope(envelope, isMine: true);

      expect(msg.id, 'msg-1');
      expect(msg.text, 'Hola peer');
      expect(msg.senderNodeId, 'my-node');
      expect(msg.receiverId, 'peer-node');
      expect(msg.isMine, isTrue);
      expect(msg.timestamp, 1710000000);
    });

    test('fromEnvelope maps correctly when message is received', () {
      final envelope = Envelope(
        messageId: 'msg-2',
        fromNodeId: 'peer-node',
        toNodeId: 'my-node',
        text: 'Respuesta de peer',
        ttl: 2,
        timestamp: 1710000050,
      );

      final msg = ChatMessage.fromEnvelope(envelope, isMine: false);

      expect(msg.id, 'msg-2');
      expect(msg.text, 'Respuesta de peer');
      expect(msg.senderNodeId, 'peer-node');
      expect(msg.receiverId, 'peer-node'); // Agrupado por el remitente
      expect(msg.isMine, isFalse);
    });

    test('fromEnvelope maps receiverId to "all" for broadcast SOS', () {
      final envelope = Envelope(
        messageId: 'sos-1',
        fromNodeId: 'remote-node',
        toNodeId: 'all',
        text: '¡Auxilio!',
        ttl: 3,
        timestamp: 1710000100,
      );

      final msg = ChatMessage.fromEnvelope(envelope, isMine: false);

      expect(msg.receiverId, 'all');
      expect(msg.senderNodeId, 'remote-node');
      expect(msg.isMine, isFalse);
    });

    test('toMap and fromMap preserves SQLite storage data format', () {
      final msg = ChatMessage(
        id: 'msg-sql-1',
        text: 'Persistencia SQLite',
        senderNodeId: 'node-x',
        receiverId: 'node-y',
        timestamp: 1710000200,
        isMine: true,
      );

      final map = msg.toMap();
      expect(map['is_mine'], 1);

      final restored = ChatMessage.fromMap(map);
      expect(restored.id, msg.id);
      expect(restored.text, msg.text);
      expect(restored.senderNodeId, msg.senderNodeId);
      expect(restored.receiverId, msg.receiverId);
      expect(restored.timestamp, msg.timestamp);
      expect(restored.isMine, isTrue);
    });
  });
}
