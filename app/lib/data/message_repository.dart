import 'message_storage.dart';
import 'models/chat_message.dart';

/// Repository shared by the UI and the background mesh service.
class MessageRepository {
  Future<bool> insert(ChatMessage message) => MessageStorage.insert(message);

  Future<List<ChatMessage>> getByConversation(String receiverId) =>
      MessageStorage.getByConversation(receiverId);

  Future<List<ConversationPreview>> getConversations() =>
      MessageStorage.getConversations();

  Future<void> deleteConversation(String receiverId) =>
      MessageStorage.deleteConversation(receiverId);

  Future<int> purgeOlderThan(int days) => MessageStorage.purgeOlderThan(days);

  Future<int> purgeBroadcasts() => MessageStorage.purgeBroadcasts();
}
