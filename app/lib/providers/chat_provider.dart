import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/message_storage.dart' show ConversationPreview;
import '../data/models/chat_message.dart';
import '../data/message_repository.dart';
import '../services/background_mesh_service.dart';

/// Provider que gestiona el historial de chat persistido en SQLite,
/// la conversación activa y la lista de conversaciones para la pantalla principal.
class ChatProvider extends ChangeNotifier {
  ChatProvider({MessageRepository? repository})
    : _repository = repository ?? MessageRepository() {
    _messageSubscription = _meshService.messageChanges.listen(
      _handleMessageChange,
    );
  }

  final MessageRepository _repository;
  final BackgroundMeshService _meshService = BackgroundMeshService.instance;
  late final StreamSubscription<Map<String, dynamic>?> _messageSubscription;

  String? _activeReceiverId;
  List<ChatMessage> _messages = [];
  List<ConversationPreview> _conversations = [];
  bool _isLoading = false;

  String? get activeReceiverId => _activeReceiverId;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<ConversationPreview> get conversations =>
      List.unmodifiable(_conversations);
  bool get isLoading => _isLoading;

  Future<void> _handleMessageChange(Map<String, dynamic>? event) async {
    try {
      await refreshFromStorage(event?['receiverId'] as String?);
    } catch (error, stackTrace) {
      debugPrint(
        '[ChatProvider] No se pudo actualizar desde SQLite: $error\n$stackTrace',
      );
    }
  }

  /// Carga la lista de conversaciones recientes desde SQLite.
  Future<void> loadConversations() async {
    _isLoading = true;
    notifyListeners();
    try {
      _conversations = await _repository.getConversations();
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
      _messages = await _repository.getByConversation(receiverId);
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
    final inserted = await _repository.insert(msg);
    if (!inserted) return;

    // Si la conversación abierta coincide con este mensaje, actualizar lista activa
    if (_activeReceiverId == msg.receiverId) {
      _messages.add(msg);
    }

    // Refrescar lista de conversaciones para actualizar último mensaje
    _conversations = await _repository.getConversations();
    notifyListeners();
  }

  Future<void> refreshFromStorage([String? receiverId]) async {
    _conversations = await _repository.getConversations();
    if (_activeReceiverId != null &&
        (receiverId == null || receiverId == _activeReceiverId)) {
      _messages = await _repository.getByConversation(_activeReceiverId!);
    }
    notifyListeners();
  }

  /// Elimina una conversación y sus mensajes.
  Future<void> deleteConversation(String receiverId) async {
    await _repository.deleteConversation(receiverId);
    if (_activeReceiverId == receiverId) {
      _messages.clear();
    }
    await loadConversations();
  }

  /// Purga mensajes más antiguos que [days] días.
  Future<int> purgeOldMessages(int days) async {
    final count = await _repository.purgeOlderThan(days);
    if (_activeReceiverId != null) {
      _messages = await _repository.getByConversation(_activeReceiverId!);
    }
    await loadConversations();
    return count;
  }

  /// Purga todos los mensajes de tipo broadcast (SOS).
  Future<int> purgeBroadcasts() async {
    final count = await _repository.purgeBroadcasts();
    if (_activeReceiverId == 'all') {
      _messages.clear();
      notifyListeners();
    }
    await loadConversations();
    return count;
  }

  @override
  void dispose() {
    _messageSubscription.cancel();
    super.dispose();
  }
}
