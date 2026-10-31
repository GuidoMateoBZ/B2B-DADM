import 'package:app/data/nearby_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NearbyService.parseStatusCode', () {
    test('extrae el código numérico del inicio del mensaje', () {
      final e = PlatformException(code: 'Failure', message: '8002: STATUS_ALREADY_DISCOVERING');
      expect(NearbyService.parseStatusCode(e), NearbyService.statusAlreadyDiscovering);
    });

    test('reconoce 8001 y 8003', () {
      expect(
        NearbyService.parseStatusCode(
          PlatformException(code: 'Failure', message: '8001: STATUS_ALREADY_ADVERTISING'),
        ),
        NearbyService.statusAlreadyAdvertising,
      );
      expect(
        NearbyService.parseStatusCode(
          PlatformException(code: 'Failure', message: '8003: STATUS_ALREADY_CONNECTED_TO_ENDPOINT'),
        ),
        NearbyService.statusAlreadyConnected,
      );
    });

    test('devuelve null si el mensaje no trae código o no es PlatformException', () {
      expect(NearbyService.parseStatusCode(PlatformException(code: 'Failure', message: 'boom')), isNull);
      expect(NearbyService.parseStatusCode(PlatformException(code: 'Failure')), isNull);
      expect(NearbyService.parseStatusCode(Exception('8002: x')), isNull);
    });
  });
}
