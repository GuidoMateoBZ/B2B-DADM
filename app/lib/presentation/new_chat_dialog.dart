import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
    final scannedNodeId = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const _NodeIdQrScannerScreen()),
    );

    if (scannedNodeId == null || !mounted) return;

    final nodeId = scannedNodeId.trim();
    setState(() {
      _controller.text = nodeId;
      _errorText = _validationErrorFor(nodeId);
    });
  }

  String? _validationErrorFor(String input) {
    if (input.isEmpty) {
      return 'Ingresá un Node ID válido';
    }

    if (widget.myNodeId != null && input == widget.myNodeId) {
      return 'No podés iniciar un chat con tu propio Node ID';
    }

    if (input.toLowerCase() == 'all') {
      return 'El identificador "all" está reservado para SOS';
    }

    if (input.length < 3) {
      return 'El Node ID es demasiado corto';
    }

    return null;
  }

  void _submit() {
    final input = _controller.text.trim();
    final error = _validationErrorFor(input);
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

class _NodeIdQrScannerScreen extends StatefulWidget {
  const _NodeIdQrScannerScreen();

  @override
  State<_NodeIdQrScannerScreen> createState() => _NodeIdQrScannerScreenState();
}

class _NodeIdQrScannerScreenState extends State<_NodeIdQrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _hasScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned || capture.barcodes.isEmpty) return;

    final value = capture.barcodes.first.rawValue;
    if (value == null || value.trim().isEmpty) return;

    _hasScanned = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Escanear Node ID')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No se pudo iniciar el escáner. Verificá que la cámara '
                  'esté disponible y que la aplicación tenga permiso para '
                  'usarla.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: Text(
              'Enfocá el código QR del otro dispositivo',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                backgroundColor: Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
