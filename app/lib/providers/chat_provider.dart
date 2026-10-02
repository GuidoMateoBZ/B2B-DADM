import 'package:flutter/foundation.dart';
import '../data/message_storage.dart';
import '../data/models/chat_message.dart';

/// Provider que gestiona el historial de chat persistido en SQLite,
/// la conversación activa y la lista de conversaciones para la pantalla principal.
class ChatProvider extends ChangeNotifier {
  String? _activeReceiverId;
  List<ChatMessage> _messages = [];
  List<ConversationPreview> _conversations = [];
  bool _isLoading = false;

  String? get activeReceiverId => _activeReceiverId;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<ConversationPreview> get conversations =>
      List.unmodifiable(_conversations);
  bool get isLoading => _isLoading;

  /// Carga la lista de conversaciones recientes desde SQLite.
  Future<void> loadConversations() async {
    _isLoading = true;
    notifyListeners();
    try {
      _conversations = await MessageStorage.getConversations();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Abre una conversación específica y carga su historial de mensajes.
  Future<void> openConversation(String receiverId) async {
    _activeReceiverId = receiverId;
    _isLoading = true;
    notifyListeners();
    try {
      _messages = await MessageStorage.getByConversation(receiverId);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cierra la conversación activa.
  void closeConversation() {
    _activeReceiverId = null;
    _messages = [];
    notifyListeners();
  }

  /// Persiste un mensaje en SQLite y actualiza el estado en memoria.
  Future<void> addMessage(ChatMessage msg) async {
    await MessageStorage.insert(msg);

    // Si la conversación abierta coincide con este mensaje, actualizar lista activa
    if (_activeReceiverId == msg.receiverId) {
      _messages.add(msg);
    }

    // Refrescar lista de conversaciones para actualizar último mensaje
    _conversations = await MessageStorage.getConversations();
    notifyListeners();
  }

  /// Elimina una conversación y sus mensajes.
  Future<void> deleteConversation(String receiverId) async {
    await MessageStorage.deleteConversation(receiverId);
    if (_activeReceiverId == receiverId) {
      _messages.clear();
    }
    await loadConversations();
  }

  /// Purga mensajes más antiguos que [days] días.
  Future<int> purgeOldMessages(int days) async {
    final count = await MessageStorage.purgeOlderThan(days);
    if (_activeReceiverId != null) {
      _messages = await MessageStorage.getByConversation(_activeReceiverId!);
    }
    await loadConversations();
    return count;
  }

  /// Purga todos los mensajes de tipo broadcast (SOS).
  Future<int> purgeBroadcasts() async {
    final count = await MessageStorage.purgeBroadcasts();
    if (_activeReceiverId == 'all') {
      _messages.clear();
      notifyListeners();
    }
    await loadConversations();
    return count;
  }
}
