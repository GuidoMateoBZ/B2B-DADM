import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/node_id_validator.dart';
import 'node_id_qr_scanner.dart';

/// Diálogo modal para iniciar una nueva conversación ingresando el Node ID del destinatario.
class NewChatDialog extends StatefulWidget {
  final String? myNodeId;

  const NewChatDialog({super.key, this.myNodeId});

  @override
  State<NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<NewChatDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _controller.text = data.text!.trim();
        _errorText = null;
      });
    }
  }

  Future<void> _scanNodeIdQr() async {
    final scannedNodeId = await scanNodeIdQr(context);

    if (scannedNodeId == null || !mounted) return;

    final nodeId = scannedNodeId.trim();
    setState(() {
      _controller.text = nodeId;
      _errorText = NodeIdValidator.validationError(
        nodeId,
        myNodeId: widget.myNodeId,
      );
    });
  }

  void _submit() {
    final input = _controller.text.trim();
    final error = NodeIdValidator.validationError(
      input,
      myNodeId: widget.myNodeId,
    );
    if (error != null) {
      setState(() {
        _errorText = error;
      });
      return;
    }

    Navigator.of(context).pop(input);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.chat_bubble_outline),
          SizedBox(width: 8),
          Text('Nuevo Chat'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ingresá el Node ID del destinatario. Si no está conectado directamente, el mensaje se propagará por nodos intermedios.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                letterSpacing: 0.5,
              ),
              decoration: InputDecoration(
                labelText: 'Node ID destinatario',
                hintText: 'ej. abc12345-6789',
                errorText: _errorText,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: 'Pegar del portapapeles',
                  onPressed: _pasteFromClipboard,
                ),
              ),
              onChanged: (_) {
                if (_errorText != null) {
                  setState(() {
                    _errorText = null;
                  });
                }
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _scanNodeIdQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Escanear QR'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Iniciar Chat')),
      ],
    );
  }
}
