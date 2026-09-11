import 'package:app/presentation/chat_screen.dart';
import 'package:app/providers/node_id_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final nodeIdProvider = context.watch<NodeIdProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'B2B',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.fingerprint,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Node ID',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (nodeIdProvider.isLoading)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 4.0),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                nodeIdProvider.nodeId ?? 'Sin ID asignado',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w500,
                                ),
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
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ChatScreen()),
                ),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Nearby Chat'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

