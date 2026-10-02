import 'envelope.dart';

/// Representa un mensaje de chat persistido localmente.
/// A diferencia de Envelope (que es el formato en tránsito),
/// ChatMessage es lo que se guarda en SQLite y se muestra en la UI.
class ChatMessage {
  final String id; // UUID del mensaje (= Envelope.messageId)
  final String text;
  final String senderNodeId; // UUID del nodo que lo envió
  final String receiverId; // UUID del nodo destino / conversación (o 'all' para SOS)
  final int timestamp; // Epoch en ms
  final bool isMine;

  ChatMessage({
    required this.id,
    required this.text,
    required this.senderNodeId,
    required this.receiverId,
    required this.timestamp,
    required this.isMine,
  });

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp);

  /// Crea un ChatMessage a partir de un Envelope recibido o enviado
  factory ChatMessage.fromEnvelope(Envelope envelope, {required bool isMine}) {
    return ChatMessage(
      id: envelope.messageId,
      text: envelope.text,
      senderNodeId: envelope.fromNodeId,
      receiverId: envelope.isBroadcast
          ? Envelope.broadcastAddress
          : (isMine ? envelope.toNodeId : envelope.fromNodeId),
      timestamp: envelope.timestamp,
      isMine: isMine,
    );
  }

  // Serialización para SQLite
  Map<String, dynamic> toMap() => {
    'id': id,
    'text': text,
    'sender_node_id': senderNodeId,
    'receiver_id': receiverId,
    'timestamp': timestamp,
    'is_mine': isMine ? 1 : 0,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'] as String,
    text: map['text'] as String,
    senderNodeId: map['sender_node_id'] as String,
    receiverId: map['receiver_id'] as String,
    timestamp: map['timestamp'] as int,
    isMine: (map['is_mine'] as int) == 1,
  );
}
