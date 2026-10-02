import 'dart:convert';
import 'package:uuid/uuid.dart';

/// Mensaje en tránsito por la red Nearby Connections.
/// Se serializa a JSON → utf8 para enviar por BLE.
///
/// Si [toNodeId] == 'all' → es un broadcast SOS.
/// Si [toNodeId] == UUID específico → es un chat 1-a-1 (puede ser multi-hop).
class Envelope {
  final String messageId; // UUID único para deduplicación
  final String fromNodeId; // UUID del nodo que originó el mensaje
  final String toNodeId; // UUID del destino final, o 'all' para broadcast
  final String text;
  final int ttl; // Saltos restantes (default: 3)
  final int timestamp; // Epoch en milisegundos

  static const String broadcastAddress = 'all';
  static const int defaultTtl = 3;

  Envelope({
    required this.messageId,
    required this.fromNodeId,
    required this.toNodeId,
    required this.text,
    required this.ttl,
    required this.timestamp,
  });

  /// Crea un Envelope nuevo para enviar
  factory Envelope.create({
    required String fromNodeId,
    required String toNodeId,
    required String text,
    int ttl = defaultTtl,
  }) {
    return Envelope(
      messageId: const Uuid().v4(),
      fromNodeId: fromNodeId,
      toNodeId: toNodeId,
      text: text,
      ttl: ttl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  bool get isBroadcast => toNodeId == broadcastAddress;

  /// Crea una copia con TTL decrementado para reenvío
  Envelope decrementTtl() => Envelope(
    messageId: messageId,
    fromNodeId: fromNodeId,
    toNodeId: toNodeId,
    text: text,
    ttl: ttl - 1,
    timestamp: timestamp,
  );

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'fromNodeId': fromNodeId,
    'toNodeId': toNodeId,
    'text': text,
    'ttl': ttl,
    'timestamp': timestamp,
  };

  factory Envelope.fromJson(Map<String, dynamic> json) => Envelope(
    messageId: json['messageId'] as String,
    fromNodeId: json['fromNodeId'] as String,
    toNodeId: json['toNodeId'] as String,
    text: json['text'] as String,
    ttl: json['ttl'] as int,
    timestamp: json['timestamp'] as int,
  );

  /// Serializa a String JSON para enviar por Nearby
  String encode() => jsonEncode(toJson());

  /// Deserializa desde String JSON recibido por Nearby
  static Envelope decode(String jsonStr) =>
      Envelope.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
}
