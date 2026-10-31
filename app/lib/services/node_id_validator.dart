class NodeIdValidator {
  static String? validationError(String value, {String? myNodeId}) {
    final nodeId = value.trim();
    if (nodeId.isEmpty) {
      return 'Ingresá un Node ID válido';
    }
    if (myNodeId != null && nodeId == myNodeId) {
      return 'No podés usar tu propio Node ID';
    }
    if (nodeId.toLowerCase() == 'all') {
      return 'El identificador "all" está reservado para SOS';
    }
    if (nodeId.length < 3) {
      return 'El Node ID es demasiado corto';
    }
    return null;
  }
}
