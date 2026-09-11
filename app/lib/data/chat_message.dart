/// Representa un mensaje de chat entre dos dispositivos.
class ChatMessage {
  final String text;
  final String senderNodeId;
  final String receiverEndpointId;
  final DateTime timestamp;

  /// `true` si el mensaje fue enviado por este dispositivo,
  /// `false` si fue recibido del peer conectado.
  /// Se usa para alinear las burbujas en la UI (derecha = mío, izquierda = recibido).
  final bool isMine;

  ChatMessage({
    required this.text,
    required this.senderNodeId,
    required this.receiverEndpointId,
    required this.timestamp,
    required this.isMine,
  });
}
