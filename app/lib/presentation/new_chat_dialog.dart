import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  void _submit() {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() {
        _errorText = 'Ingresá un Node ID válido';
      });
      return;
    }

    if (widget.myNodeId != null && input == widget.myNodeId) {
      setState(() {
        _errorText = 'No podés iniciar un chat con tu propio Node ID';
      });
      return;
    }

    if (input.toLowerCase() == 'all') {
      setState(() {
        _errorText = 'El identificador "all" está reservado para SOS';
      });
      return;
    }

    if (input.length < 3) {
      setState(() {
        _errorText = 'El Node ID es demasiado corto';
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Iniciar Chat'),
        ),
      ],
    );
  }
}
