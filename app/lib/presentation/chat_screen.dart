import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/nearby_provider.dart';
import '../services/local_notification_service.dart';

/// Pantalla de chat 1-a-1 con un nodo específico (por Node ID / UUID).
/// Soporta comunicación directa o multi-hop ruteada a través de la red mesh.
class ChatScreen extends StatefulWidget {
  final String? targetNodeId;

  const ChatScreen({super.key, this.targetNodeId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String? _resolvedTargetNodeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        localNotificationService.requestPermission();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeArgs = ModalRoute.of(context)?.settings.arguments;
    final target = widget.targetNodeId ?? (routeArgs is String ? routeArgs : null);

    if (target != null && target != _resolvedTargetNodeId) {
      _resolvedTargetNodeId = target;
      context.read<ChatProvider>().openConversation(target);
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    final target = _resolvedTargetNodeId;
    if (text.isEmpty || target == null) return;

    _messageController.clear();
    await context.read<NearbyProvider>().sendChatMessage(target, text);
    _scrollToBottom();
  }

  String _formatTimestamp(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');

    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${pad(dt.hour)}:${pad(dt.minute)}';
    }
    return '${pad(dt.day)}/${pad(dt.month)} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final nearbyProvider = context.watch<NearbyProvider>();
    final target = _resolvedTargetNodeId ?? 'Desconocido';
    final reachability = nearbyProvider.getReachability(target);
    final messages = chatProvider.messages;
    final theme = Theme.of(context);

    if (messages.isNotEmpty) {
      _scrollToBottom();
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              target,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            Row(
              children: [
                _buildReachabilityDot(reachability),
                const SizedBox(width: 5),
                Text(
                  _buildReachabilityLabel(reachability),
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'Copiar Node ID del contacto',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: target));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Node ID copiado al portapapeles'),
                  duration: Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (val) async {
              if (val == 'delete') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Eliminar historial'),
                    content: const Text(
                      '¿Deseás borrar todos los mensajes de esta conversación?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancelar'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Eliminar'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  await chatProvider.deleteConversation(target);
                  if (context.mounted) Navigator.of(context).pop();
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 20),
                    SizedBox(width: 8),
                    Text('Eliminar conversación'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner de advertencia si no hay ruta
          if (reachability == NodeReachability.unreachable)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.amber.withValues(alpha: 0.15),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Sin vecinos conectados. El mensaje se guardará y se podrá enviar cuando haya nodos en la red.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Lista de mensajes de la conversación
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 48,
                          color: theme.colorScheme.outlineVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No hay mensajes aún',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Escribí un mensaje para iniciar la conversación',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return _buildMessageBubble(context, msg);
                    },
                  ),
          ),

          // Input de mensaje
          Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      textCapitalization: TextCapitalization.sentences,
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
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReachabilityDot(NodeReachability reachability) {
    Color color;
    switch (reachability) {
      case NodeReachability.direct:
        color = Colors.green;
        break;
      case NodeReachability.multihop:
        color = Colors.amber;
        break;
      case NodeReachability.unreachable:
        color = Colors.red;
        break;
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  String _buildReachabilityLabel(NodeReachability reachability) {
    switch (reachability) {
      case NodeReachability.direct:
        return 'Vecino directo';
      case NodeReachability.multihop:
        return 'Alcanzable por multi-hop';
      case NodeReachability.unreachable:
        return 'Sin ruta en este momento';
    }
  }

  Widget _buildMessageBubble(BuildContext context, ChatMessage msg) {
    final theme = Theme.of(context);
    final isMine = msg.isMine;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMine
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
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
            if (!isMine) ...[
              Text(
                msg.senderNodeId,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 2),
            ],
            Text(
              msg.text,
              style: TextStyle(
                fontSize: 14,
                color: isMine
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTimestamp(msg.timestamp),
              style: TextStyle(
                fontSize: 10,
                color: (isMine
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface)
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
