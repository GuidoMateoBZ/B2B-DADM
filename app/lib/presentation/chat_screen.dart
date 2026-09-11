import 'package:app/providers/nearby_provider.dart';
import 'package:app/providers/node_id_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Pantalla de Nearby Chat con dos vistas:
/// - Discovery: buscar y conectarse a dispositivos cercanos
/// - Chat: enviar y recibir mensajes con el peer conectado
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    // Scroll al final después de que se renderice el nuevo mensaje
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nearbyProvider = context.watch<NearbyProvider>();

    return Scaffold(
      appBar: _buildAppBar(context, nearbyProvider),
      body: nearbyProvider.state == NearbyState.connected
          ? _buildChatView(context, nearbyProvider)
          : _buildDiscoveryView(context, nearbyProvider),
    );
  }

  // ── AppBar ──

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    NearbyProvider nearbyProvider,
  ) {
    final isConnected = nearbyProvider.state == NearbyState.connected;

    return AppBar(
      title: Text(
        isConnected
            ? 'Chat con ${_shortenId(nearbyProvider.connectedEndpointName ?? '')}'
            : 'Nearby Chat',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      actions: [
        if (isConnected)
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: 'Desconectar',
            onPressed: () => nearbyProvider.disconnect(),
          ),
        if (nearbyProvider.state == NearbyState.searching)
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined),
            tooltip: 'Detener búsqueda',
            onPressed: () => nearbyProvider.stopSearching(),
          ),
      ],
    );
  }

  // ── Vista de Discovery ──

  Widget _buildDiscoveryView(
    BuildContext context,
    NearbyProvider nearbyProvider,
  ) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Mensaje de error
            if (nearbyProvider.errorMessage != null) ...[
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          nearbyProvider.errorMessage!,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Botón principal
            if (nearbyProvider.state == NearbyState.idle ||
                nearbyProvider.state == NearbyState.error)
              FilledButton.icon(
                onPressed: () {
                  final nodeId = context.read<NodeIdProvider>().nodeId;
                  if (nodeId != null) {
                    nearbyProvider.startSearching(nodeId);
                  }
                },
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Buscar Dispositivos'),
              ),

            if (nearbyProvider.state == NearbyState.searching) ...[
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Buscando dispositivos cercanos...'),
                ],
              ),
            ],

            if (nearbyProvider.state == NearbyState.connecting) ...[
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Conectando...'),
                ],
              ),
            ],

            const SizedBox(height: 24),

            // Lista de dispositivos descubiertos
            if (nearbyProvider.discoveredEndpoints.isNotEmpty) ...[
              Text(
                'Dispositivos Cercanos',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: nearbyProvider.discoveredEndpoints.length,
                  itemBuilder: (context, index) {
                    final endpoint =
                        nearbyProvider.discoveredEndpoints[index];
                    return Card(
                      elevation: 0,
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      child: ListTile(
                        leading: Icon(
                          Icons.phone_android,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(
                          _shortenId(endpoint.userName),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          'Endpoint: ${_shortenId(endpoint.endpointId)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        trailing: FilledButton.tonal(
                          onPressed: nearbyProvider.state ==
                                  NearbyState.connecting
                              ? null
                              : () =>
                                  nearbyProvider.connectTo(endpoint.endpointId),
                          child: const Text('Conectar'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ] else if (nearbyProvider.state == NearbyState.searching) ...[
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.radar, size: 48, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        'Escaneando...\nAsegurate de que el otro dispositivo\ntambién esté buscando.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Vista de Chat ──

  Widget _buildChatView(
    BuildContext context,
    NearbyProvider nearbyProvider,
  ) {
    // Scroll automático cuando llegan mensajes nuevos
    _scrollToBottom();

    return SafeArea(
      child: Column(
        children: [
          // Lista de mensajes
          Expanded(
            child: nearbyProvider.messages.isEmpty
                ? const Center(
                    child: Text(
                      '¡Conectados! Enviá el primer mensaje.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: nearbyProvider.messages.length,
                    itemBuilder: (context, index) {
                      final message = nearbyProvider.messages[index];
                      return _MessageBubble(message: message);
                    },
                  ),
          ),

          // Divider
          const Divider(height: 1),

          // Input de mensaje
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Escribí un mensaje...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(nearbyProvider),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: () => _sendMessage(nearbyProvider),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _sendMessage(NearbyProvider nearbyProvider) {
    final text = _messageController.text;
    if (text.trim().isEmpty) return;

    nearbyProvider.sendMessage(text);
    _messageController.clear();
  }

  /// Acorta un UUID o ID largo para mostrar en la UI.
  String _shortenId(String id) {
    if (id.length > 12) {
      return '${id.substring(0, 8)}...${id.substring(id.length - 4)}';
    }
    return id;
  }
}

// ── Widget de burbuja de mensaje ──

class _MessageBubble extends StatelessWidget {
  final dynamic message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isMine = message.isMine;
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMine
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMine ? 16 : 4),
            bottomRight: Radius.circular(isMine ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: isMine
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                fontSize: 11,
                color: isMine
                    ? colorScheme.onPrimaryContainer.withValues(alpha: 0.6)
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
