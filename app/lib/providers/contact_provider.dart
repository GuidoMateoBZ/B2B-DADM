import 'package:flutter/foundation.dart';

import '../data/contact_storage.dart';
import '../data/models/mesh_contact.dart';

class ContactProvider extends ChangeNotifier {
  List<MeshContact> _contacts = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<MeshContact> get contacts => List.unmodifiable(_contacts);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  MeshContact? findByNodeId(String nodeId) {
    for (final contact in _contacts) {
      if (contact.nodeId == nodeId) return contact;
    }
    return null;
  }

  Future<void> loadContacts() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _contacts = await ContactStorage.getAll();
    } catch (error, stackTrace) {
      _errorMessage = 'No se pudieron cargar los contactos: $error';
      debugPrint('[ContactProvider] $_errorMessage\n$stackTrace');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> addContact(String nodeId, String? alias) async {
    final contact = MeshContact(
      nodeId: nodeId,
      alias: _normalizeAlias(alias),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final inserted = await ContactStorage.insert(contact);
    if (inserted) {
      _contacts = await ContactStorage.getAll();
      notifyListeners();
    }
    return inserted;
  }

  Future<void> updateAlias(String nodeId, String? alias) async {
    await ContactStorage.updateAlias(nodeId, _normalizeAlias(alias));
    _contacts = await ContactStorage.getAll();
    notifyListeners();
  }

  Future<void> removeContact(String nodeId) async {
    await ContactStorage.delete(nodeId);
    _contacts = await ContactStorage.getAll();
    notifyListeners();
  }

  String? _normalizeAlias(String? alias) {
    final value = alias?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}
