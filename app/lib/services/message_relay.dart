import '../data/models/envelope.dart';

/// Resultado del procesamiento de un Envelope entrante.
enum RelayAction {
  deliver, // Es para mí → mostrar en UI + persistir
  forward, // No es para mí → reenviar a vecinos
  discard, // Ya lo vi o TTL agotado → ignorar
}

class RelayResult {
  final RelayAction action;
  final Envelope envelope;

  /// endpointIds a los que se debe reenviar (vacío si action != forward y no hay reenvío de broadcast)
  final List<String> forwardTo;

  RelayResult({
    required this.action,
    required this.envelope,
    this.forwardTo = const [],
  });
}

class MessageRelay {
  final String myNodeId;

  /// Set de messageIds ya procesados (evita loops y duplicados)
  final Set<String> _seenMessageIds = {};

  /// Tabla de vecinos conectados: endpointId → nodeId
  final Map<String, String> _neighbors = {};

  /// Inversa: nodeId → endpointId (para envío directo)
  final Map<String, String> _nodeToEndpoint = {};

  MessageRelay({required this.myNodeId});

  // ── Gestión de vecinos ──

  void addNeighbor(String endpointId, String nodeId) {
    _neighbors[endpointId] = nodeId;
    _nodeToEndpoint[nodeId] = endpointId;
  }

  void removeNeighbor(String endpointId) {
    final nodeId = _neighbors.remove(endpointId);
    if (nodeId != null) _nodeToEndpoint.remove(nodeId);
  }

  Map<String, String> get neighbors => Map.unmodifiable(_neighbors);

  /// Busca si el nodo destino es un vecino directo.
  /// Retorna el endpointId si lo es, null si no.
  String? findDirectEndpoint(String nodeId) => _nodeToEndpoint[nodeId];

  // ── Procesamiento de mensajes entrantes ──

  /// Procesa un Envelope recibido de [fromEndpointId].
  ///
  /// Retorna un [RelayResult] que indica qué hacer:
  /// - deliver: es para mí (o broadcast) → mostrar al usuario
  /// - forward: no es para mí, TTL > 0 → reenviar
  /// - discard: duplicado o TTL agotado
  RelayResult processIncoming(String fromEndpointId, Envelope envelope) {
    // 1. Deduplicación: ¿ya vi este mensaje?
    if (_seenMessageIds.contains(envelope.messageId)) {
      return RelayResult(action: RelayAction.discard, envelope: envelope);
    }
    _seenMessageIds.add(envelope.messageId);

    // 2. ¿Es para mí o es broadcast?
    final isForMe = envelope.toNodeId == myNodeId;
    final isBroadcast = envelope.isBroadcast;

    if (isForMe) {
      // Chat 1-a-1 dirigido a mí → entregar, no reenviar
      return RelayResult(action: RelayAction.deliver, envelope: envelope);
    }

    if (isBroadcast) {
      // Broadcast: entregar al usuario Y reenviar a todos (excepto quien lo mandó)
      final forwardTargets = _neighbors.keys
          .where((eid) => eid != fromEndpointId)
          .toList();

      if (envelope.ttl > 0 && forwardTargets.isNotEmpty) {
        return RelayResult(
          action: RelayAction.deliver, // Mostrar + reenviar
          envelope: envelope.decrementTtl(),
          forwardTo: forwardTargets,
        );
      }
      // TTL agotado → solo entregar, no reenviar
      return RelayResult(action: RelayAction.deliver, envelope: envelope);
    }

    // 3. No es para mí ni es broadcast → reenviar si TTL > 0
    if (envelope.ttl <= 0) {
      return RelayResult(action: RelayAction.discard, envelope: envelope);
    }

    // Buscar ruta: ¿tengo al destino como vecino directo?
    final directEndpoint = findDirectEndpoint(envelope.toNodeId);
    final forwardTargets = directEndpoint != null
        ? [directEndpoint] // Envío directo al destino
        : _neighbors.keys // Flooding: enviar a todos excepto quien me lo mandó
            .where((eid) => eid != fromEndpointId)
            .toList();

    return RelayResult(
      action: RelayAction.forward,
      envelope: envelope.decrementTtl(),
      forwardTo: forwardTargets,
    );
  }

  // ── Creación de mensajes salientes ──

  /// Determina los endpointIds a los que enviar un nuevo mensaje mío.
  List<String> getTargetEndpoints(Envelope envelope) {
    _seenMessageIds.add(envelope.messageId);

    if (envelope.isBroadcast) {
      // SOS → enviar a todos los vecinos
      return _neighbors.keys.toList();
    }

    // Chat 1-a-1: ¿el destino es vecino directo?
    final directEndpoint = findDirectEndpoint(envelope.toNodeId);
    if (directEndpoint != null) {
      return [directEndpoint]; // Envío directo
    }

    // No es vecino directo → flooding a todos los vecinos
    return _neighbors.keys.toList();
  }

  // ── Limpieza ──

  /// Limpia el set de mensajes vistos (para liberar memoria en sesiones largas)
  void clearSeenMessages() => _seenMessageIds.clear();
}
