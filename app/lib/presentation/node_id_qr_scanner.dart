import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

Future<String?> scanNodeIdQr(BuildContext context) => Navigator.of(context)
    .push<String>(
      MaterialPageRoute<String>(builder: (_) => const NodeIdQrScannerScreen()),
    );

class NodeIdQrScannerScreen extends StatefulWidget {
  const NodeIdQrScannerScreen({super.key});

  @override
  State<NodeIdQrScannerScreen> createState() => _NodeIdQrScannerScreenState();
}

class _NodeIdQrScannerScreenState extends State<NodeIdQrScannerScreen> {
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
