import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/message_storage.dart';
import '../providers/chat_provider.dart';
import '../providers/nearby_provider.dart';
import '../providers/node_id_provider.dart';
import '../services/local_notification_service.dart';
import 'new_chat_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ChatProvider>().loadConversations();
      }
    });
  }

  Future<void> _openNewChat(String? myNodeId) async {
    final targetNodeId = await showDialog<String>(
      context: context,
      builder: (_) => NewChatDialog(myNodeId: myNodeId),
    );

    if (targetNodeId != null && mounted) {
      await Navigator.pushNamed(
        context,
        chatRouteName,
        arguments: targetNodeId,
      );
      if (mounted) {
        context.read<ChatProvider>().loadConversations();
      }
    }
  }

  Future<void> _confirmPurgeOldMessages() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.cleaning_services_outlined),
            SizedBox(width: 8),
            Text('Purgar Mensajes'),
          ],
        ),
        content: const Text(
          '¿Deseás eliminar todos los mensajes con más de 30 días de antigüedad?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Purgar'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final count = await context.read<ChatProvider>().purgeOldMessages(30);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Se eliminaron $count mensajes antiguos'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showConnectedNeighbors(BuildContext context, NearbyProvider nearby) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final neighbors = nearby.connectedEndpoints.entries.toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20.0),
                  child: Text(
                    'Vecinos Conectados Directamente',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 12),
                if (neighbors.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20.0),
                    child: Text('No hay vecinos conectados en este momento.'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: neighbors.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final entry = neighbors[i];
                        return ListTile(
                          leading: const Icon(
                            Icons.phonelink_ring,
                            color: Colors.green,
                          ),
                          title: Text(
                            entry.value,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'Endpoint ID: ${entry.key}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.link_off),
                            tooltip: 'Desconectar',
                            onPressed: () {
                              nearby.disconnectEndpoint(entry.key);
                              Navigator.of(ctx).pop();
                            },
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
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
    final nodeIdProvider = context.watch<NodeIdProvider>();
    final nearbyProvider = context.watch<NearbyProvider>();
    final chatProvider = context.watch<ChatProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'B2B Mesh',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          // Botón directo a Broadcast / SOS
          IconButton(
            icon: const Icon(Icons.emergency, color: Colors.red),
            tooltip: 'Alertas SOS',
            onPressed: () async {
              await Navigator.pushNamed(context, broadcastRouteName);
              if (mounted) chatProvider.loadConversations();
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (val) {
              if (val == 'purge') {
                _confirmPurgeOldMessages();
              } else if (val == 'neighbors') {
                _showConnectedNeighbors(context, nearbyProvider);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'neighbors',
                child: Row(
                  children: [
                    const Icon(Icons.devices, size: 20),
                    const SizedBox(width: 8),
                    Text('Vecinos (${nearbyProvider.connectedCount})'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'purge',
                child: Row(
                  children: [
                    const Icon(Icons.cleaning_services, size: 20),
                    const SizedBox(width: 8),
                    const Text('Purgar mensajes antiguos'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openNewChat(nodeIdProvider.nodeId),
        icon: const Icon(Icons.add_comment),
        label: const Text('Nuevo Chat'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Card: Node ID propio
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 12.0,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.fingerprint,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Mi Node ID',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            SelectableText(
                              nodeIdProvider.nodeId ?? 'Cargando ID...',
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (nodeIdProvider.nodeId != null)
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: 'Copiar Node ID',
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: nodeIdProvider.nodeId!),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Node ID copiado al portapapeles'),
                                duration: Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // Card: Control de Red / Estado de Vecinos
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _buildStatusIcon(nearbyProvider),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _buildStatusText(nearbyProvider),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                if (nearbyProvider.connectedCount > 0)
                                  GestureDetector(
                                    onTap: () => _showConnectedNeighbors(
                                      context,
                                      nearbyProvider,
                                    ),
                                    child: Text(
                                      '${nearbyProvider.connectedCount} vecino(s) conectado(s) - Toca para ver',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: theme.colorScheme.primary,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          _buildSearchToggleButton(
                            context,
                            nearbyProvider,
                            nodeIdProvider.nodeId,
                          ),
                        ],
                      ),
                      if (nearbyProvider.errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          nearbyProvider.errorMessage!,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Título de la lista de conversaciones
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Conversaciones',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  if (chatProvider.isLoading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),

            // Lista de Conversaciones
            Expanded(
              child: chatProvider.conversations.isEmpty
                  ? _buildEmptyConversationsView(theme, nodeIdProvider.nodeId)
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 80, top: 4),
                      itemCount: chatProvider.conversations.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final conv = chatProvider.conversations[index];
                        return _buildConversationTile(
                          context,
                          conv,
                          nearbyProvider,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(NearbyProvider nearby) {
    if (nearby.state == NearbyState.connecting ||
        (nearby.isSearching && nearby.connectedCount == 0)) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (nearby.connectedCount > 0) {
      return const Icon(Icons.circle, color: Colors.green, size: 14);
    }
    if (nearby.state == NearbyState.error) {
      return const Icon(Icons.error_outline, color: Colors.red, size: 16);
    }
    return const Icon(Icons.circle_outlined, color: Colors.grey, size: 14);
  }

  String _buildStatusText(NearbyProvider nearby) {
    if (nearby.connectedCount > 0) {
      return nearby.isSearching
          ? 'Red Mesh activa (Buscando vecinos)'
          : 'Red Mesh conectada';
    }
    if (nearby.isSearching) {
      return 'Buscando vecinos cercanos...';
    }
    if (nearby.state == NearbyState.connecting) {
      return 'Conectando con vecino...';
    }
    if (nearby.state == NearbyState.error) {
      return 'Error de red Nearby';
    }
    return 'Búsqueda inactiva';
  }

  Widget _buildSearchToggleButton(
    BuildContext context,
    NearbyProvider nearby,
    String? nodeId,
  ) {
    if (nearby.isSearching) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
        onPressed: () => nearby.stopSearching(),
        icon: const Icon(Icons.stop, size: 16),
        label: const Text('Detener', style: TextStyle(fontSize: 12)),
      );
    }

    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      onPressed: nodeId != null ? () => nearby.startSearching(nodeId) : null,
      icon: const Icon(Icons.radar, size: 16),
      label: const Text('Buscar', style: TextStyle(fontSize: 12)),
    );
  }

  Widget _buildEmptyConversationsView(ThemeData theme, String? myNodeId) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 56,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No hay conversaciones',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Tocá "Nuevo Chat" para iniciar una conversación ingresando el Node ID de otro usuario, o activá la búsqueda para formar la red.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(
    BuildContext context,
    ConversationPreview conv,
    NearbyProvider nearby,
  ) {
    final theme = Theme.of(context);
    final isSos = conv.isBroadcast;

    if (isSos) {
      return ListTile(
        leading: const CircleAvatar(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
          child: Icon(Icons.emergency, size: 20),
        ),
        title: const Text(
          '🚨 Alertas SOS (Broadcast)',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.red,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          conv.lastMessageText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Text(
          _formatTimestamp(conv.lastTimestamp),
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
        ),
        onTap: () async {
          await Navigator.pushNamed(context, broadcastRouteName);
          if (context.mounted) {
            context.read<ChatProvider>().loadConversations();
          }
        },
      );
    }

    // Chat 1-a-1
    final reachability = nearby.getReachability(conv.peerNodeId);
    Color statusColor;
    String statusTooltip;
    switch (reachability) {
      case NodeReachability.direct:
        statusColor = Colors.green;
        statusTooltip = 'Vecino directo';
        break;
      case NodeReachability.multihop:
        statusColor = Colors.amber;
        statusTooltip = 'Alcanzable por multi-hop';
        break;
      case NodeReachability.unreachable:
        statusColor = Colors.grey;
        statusTooltip = 'Sin ruta en este momento';
        break;
    }

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
            child: const Icon(Icons.person_outline, size: 22),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Tooltip(
              message: statusTooltip,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        conv.peerNodeId,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
      subtitle: Text(
        conv.lastMessageText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Text(
        _formatTimestamp(conv.lastTimestamp),
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
      ),
      onTap: () async {
        await Navigator.pushNamed(
          context,
          chatRouteName,
          arguments: conv.peerNodeId,
        );
        if (context.mounted) {
          context.read<ChatProvider>().loadConversations();
        }
      },
      onLongPress: () => _confirmDeleteConversation(conv.peerNodeId),
    );
  }

  Future<void> _confirmDeleteConversation(String peerNodeId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar conversación'),
        content: Text(
          '¿Estás seguro de que querés eliminar la conversación con $peerNodeId?',
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

    if (confirmed == true && mounted) {
      await context.read<ChatProvider>().deleteConversation(peerNodeId);
    }
  }
}
