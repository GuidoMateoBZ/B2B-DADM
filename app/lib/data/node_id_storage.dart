import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Gestiona y persiste el id del nodo para la sesión de Google Nearby Connections
class NodeIdStorage {
  static const _key = 'node_id';


  /// Obtiene el uuid en memoria o genera uno nuevo si no existe
  Future<String> getId() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_key);
    if (existing != null) return existing;
    
    final newId = const Uuid().v4();
    await preferences.setString(_key, newId);
    return newId;
  }

}