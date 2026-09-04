import 'package:app/providers/node_id_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomeScreen extends StatelessWidget {
  
  const HomeScreen({super.key}); //Constructor

  @override
  Widget build(BuildContext context) {
    final nodeIdProvider = context.watch<NodeIdProvider>();

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Hello, B2B!', style: TextStyle(fontSize: 24)),
            const SizedBox(height: 16),
            if (nodeIdProvider.isLoading)
              const CircularProgressIndicator()
            else
              SelectableText(
                'Node ID: ${nodeIdProvider.nodeId!}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontFamily: 'monospace',
                ),
              )
          ],
        ),
      ),
    );
  }
}
