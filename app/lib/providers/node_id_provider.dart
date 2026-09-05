import 'package:flutter/foundation.dart';

import '../data/node_id_storage.dart';

// Al hacer que extienda de ChangeNotifier indicamos que es un emisor de eventos de estado (tipo Observer)
class NodeIdProvider extends ChangeNotifier {
  final NodeIdStorage _storage = NodeIdStorage();

  String? _nodeId;
  String? get nodeId => _nodeId;

  bool get isLoading => _nodeId == null;

  Future<void> loadId() async {
    _nodeId = await _storage.getId();
    notifyListeners(); //Notifica a los suscriptores que se vuelven a buildear para redibujar la info actualizada
  }

}

