import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/nearby_provider.dart';

/// Pantalla dedicada a la visualización y emisión de alertas de emergencia SOS (Broadcast epidémico).
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key});

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ChatProvider>().openConversation('all');
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
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

  Future<void> _sendSos() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    _textController.clear();
    await context.read<NearbyProvider>().sendBroadcast(text);
    _scrollToBottom();
  }

  Future<void> _confirmPurge() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text('Purgar Alertas SOS'),
          ],
        ),
        content: const Text(
          '¿Estás seguro de que querés eliminar todos los mensajes de emergencia SOS guardados?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar Todo'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final count = await context.read<ChatProvider>().purgeBroadcasts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Se eliminaron $count mensajes SOS'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
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
    final messages = chatProvider.messages;
    final theme = Theme.of(context);

    // Auto-scroll si hay mensajes nuevos
    if (messages.isNotEmpty) {
      _scrollToBottom();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.emergency, color: Colors.red),
            SizedBox(width: 8),
            Text('Alertas SOS', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Purgar mensajes SOS',
            onPressed: messages.isEmpty ? null : _confirmPurge,
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner informativo de red
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.red.withValues(alpha: 0.08),
            child: Row(
              children: [
                const Icon(Icons.wifi_tethering, size: 20, color: Colors.red),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    nearbyProvider.connectedCount > 0
                        ? 'Difusión epidémica: alcanzando ${nearbyProvider.connectedCount} vecino(s) directos + reenvío multi-hop'
                        : 'Sin vecinos conectados: la alerta se guardará localmente',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.red.shade900,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Lista de mensajes SOS
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.notifications_off_outlined,
                          size: 64,
                          color: theme.colorScheme.outlineVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No hay alertas SOS registradas',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Los mensajes de emergencia broadcast aparecerán acá',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return _buildSosCard(context, msg);
                    },
                  ),
          ),

          // Barra inferior de envío
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
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
                      controller: _textController,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Escribí una alerta de emergencia...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _sendSos(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(14),
                    ),
                    onPressed: _sendSos,
                    child: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSosCard(BuildContext context, ChatMessage msg) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 1,
      color: msg.isMine ? Colors.red.shade50 : Colors.orange.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: msg.isMine ? Colors.red.shade300 : Colors.orange.shade300,
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.warning,
                      size: 18,
                      color: msg.isMine ? Colors.red : Colors.deepOrange,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      msg.isMine ? 'SOS (Enviado por mí)' : 'SOS de ${msg.senderNodeId}',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: msg.isMine ? Colors.red.shade900 : Colors.deepOrange.shade900,
                      ),
                    ),
                  ],
                ),
                Text(
                  _formatTimestamp(msg.timestamp),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade700,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              msg.text,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
