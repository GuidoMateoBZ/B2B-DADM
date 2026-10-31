import 'package:sqflite/sqflite.dart';

import 'message_storage.dart';
import 'models/mesh_contact.dart';

class ContactStorage {
  static Future<List<MeshContact>> getAll() async {
    final db = await MessageStorage.database;
    final rows = await db.query('contacts', orderBy: 'created_at DESC');
    return rows.map(MeshContact.fromMap).toList();
  }

  static Future<MeshContact?> getByNodeId(String nodeId) async {
    final db = await MessageStorage.database;
    final rows = await db.query(
      'contacts',
      where: 'node_id = ?',
      whereArgs: [nodeId],
      limit: 1,
    );
    return rows.isEmpty ? null : MeshContact.fromMap(rows.first);
  }

  static Future<bool> insert(MeshContact contact) async {
    final db = await MessageStorage.database;
    final rowId = await db.insert(
      'contacts',
      contact.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rowId != -1;
  }

  static Future<void> updateAlias(String nodeId, String? alias) async {
    final db = await MessageStorage.database;
    await db.update(
      'contacts',
      {'alias': alias},
      where: 'node_id = ?',
      whereArgs: [nodeId],
    );
  }

  static Future<void> delete(String nodeId) async {
    final db = await MessageStorage.database;
    await db.delete('contacts', where: 'node_id = ?', whereArgs: [nodeId]);
  }
}
