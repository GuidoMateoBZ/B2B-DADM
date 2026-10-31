import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/node_id_validator.dart';
import 'node_id_qr_scanner.dart';

class ContactFormResult {
  const ContactFormResult({required this.nodeId, required this.alias});

  final String nodeId;
  final String? alias;
}

class ContactFormDialog extends StatefulWidget {
  const ContactFormDialog({
    super.key,
    required this.myNodeId,
    this.existingNodeId,
    this.initialNodeId,
    this.initialAlias,
  });

  final String? myNodeId;
  final String? existingNodeId;
  final String? initialNodeId;
  final String? initialAlias;

  @override
  State<ContactFormDialog> createState() => _ContactFormDialogState();
}

class _ContactFormDialogState extends State<ContactFormDialog> {
  late final TextEditingController _nodeIdController = TextEditingController(
    text: widget.existingNodeId ?? widget.initialNodeId ?? '',
  );
  late final TextEditingController _aliasController = TextEditingController(
    text: widget.initialAlias ?? '',
  );
  String? _errorText;

  bool get _isEditing => widget.existingNodeId != null;

  @override
  void dispose() {
    _nodeIdController.dispose();
    _aliasController.dispose();
    super.dispose();
  }

  Future<void> _pasteNodeId() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text?.trim();
    if (value == null || value.isEmpty || !mounted) return;
    _nodeIdController.text = value;
    setState(() => _errorText = null);
  }

  Future<void> _scanNodeId() async {
    final value = await scanNodeIdQr(context);
    if (value == null || !mounted) return;
    _nodeIdController.text = value.trim();
    setState(() {
      _errorText = NodeIdValidator.validationError(
        _nodeIdController.text,
        myNodeId: widget.myNodeId,
      );
    });
  }

  void _submit() {
    final nodeId = _nodeIdController.text.trim();
    final validationError = _isEditing
        ? null
        : NodeIdValidator.validationError(nodeId, myNodeId: widget.myNodeId);
    if (validationError != null) {
      setState(() => _errorText = validationError);
      return;
    }

    final alias = _aliasController.text.trim();
    Navigator.of(context).pop(
      ContactFormResult(
        nodeId: widget.existingNodeId ?? nodeId,
        alias: alias.isEmpty ? null : alias,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(_isEditing ? Icons.edit_outlined : Icons.person_add_alt_1),
          const SizedBox(width: 8),
          Text(_isEditing ? 'Editar contacto' : 'Agregar contacto'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isEditing
                  ? 'El alias es privado y solo se guarda en este dispositivo.'
                  : 'Guardalo en tu agenda para encontrarlo fácilmente. '
                        'El alias es privado y solo se guarda en este dispositivo.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nodeIdController,
              readOnly: _isEditing,
              autofocus: !_isEditing,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Node ID',
                errorText: _errorText,
                border: const OutlineInputBorder(),
                suffixIcon: _isEditing
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.content_paste),
                        tooltip: 'Pegar del portapapeles',
                        onPressed: _pasteNodeId,
                      ),
              ),
              onChanged: (_) {
                if (_errorText != null) setState(() => _errorText = null);
              },
            ),
            if (!_isEditing) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _scanNodeId,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Escanear QR'),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _aliasController,
              textCapitalization: TextCapitalization.words,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Alias (opcional)',
                hintText: 'Ej. Pepe',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_isEditing ? 'Guardar cambios' : 'Guardar contacto'),
        ),
      ],
    );
  }
}
