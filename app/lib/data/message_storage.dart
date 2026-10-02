import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'models/chat_message.dart';

/// Vista previa de una conversación para la lista en Home.
class ConversationPreview {
  final String peerNodeId; // UUID del otro nodo o 'all'
  final String lastMessageText;
  final int lastTimestamp;
  final bool isBroadcast; // true si peerNodeId == 'all'

  ConversationPreview({
    required this.peerNodeId,
    required this.lastMessageText,
    required this.lastTimestamp,
    this.isBroadcast = false,
  });

  DateTime get lastDateTime =>
      DateTime.fromMillisecondsSinceEpoch(lastTimestamp);
}

class MessageStorage {
  static Database? _db;

  static Future<Database> get database async {
    _db ??= await openDatabase(
      join(await getDatabasesPath(), 'b2b_messages.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            sender_node_id TEXT NOT NULL,
            receiver_id TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            is_mine INTEGER NOT NULL
          )
        ''');
        // Índice para queries por conversación y ordenamiento
        await db.execute(
          'CREATE INDEX idx_receiver_timestamp ON messages(receiver_id, timestamp)',
        );
      },
    );
    return _db!;
  }

  /// Guarda un mensaje (upsert: ignora si ya existe por id)
  static Future<void> insert(ChatMessage msg) async {
    final db = await database;
    await db.insert(
      'messages',
      msg.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Obtiene todos los mensajes de una conversación ordenados por timestamp
  static Future<List<ChatMessage>> getByConversation(String receiverId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'receiver_id = ?',
      whereArgs: [receiverId],
      orderBy: 'timestamp ASC',
    );
    return rows.map((r) => ChatMessage.fromMap(r)).toList();
  }

  /// Obtiene la lista de conversaciones con el último mensaje
  static Future<List<ConversationPreview>> getConversations() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT m.receiver_id, m.text, m.timestamp
      FROM messages m
      INNER JOIN (
        SELECT receiver_id, MAX(timestamp) as max_timestamp
        FROM messages
        GROUP BY receiver_id
      ) latest ON m.receiver_id = latest.receiver_id AND m.timestamp = latest.max_timestamp
      GROUP BY m.receiver_id
      ORDER BY m.timestamp DESC
    ''');
    return rows.map((r) => ConversationPreview(
      peerNodeId: r['receiver_id'] as String,
      lastMessageText: r['text'] as String,
      lastTimestamp: r['timestamp'] as int,
      isBroadcast: r['receiver_id'] == 'all',
    )).toList();
  }

  /// Elimina los mensajes de una conversación
  static Future<void> deleteConversation(String receiverId) async {
    final db = await database;
    await db.delete('messages', where: 'receiver_id = ?', whereArgs: [receiverId]);
  }

  /// Purga: elimina mensajes más antiguos que [days] días
  static Future<int> purgeOlderThan(int days) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    return await db.delete('messages', where: 'timestamp < ?', whereArgs: [cutoff]);
  }

  /// Purga: elimina todos los mensajes SOS (receiver_id = 'all')
  static Future<int> purgeBroadcasts() async {
    final db = await database;
    return await db.delete('messages', where: 'receiver_id = ?', whereArgs: ['all']);
  }
}
