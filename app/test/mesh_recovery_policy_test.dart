import 'package:app/data/models/media_state.dart';
import 'package:app/services/mesh_recovery_policy.dart';
import 'package:flutter_test/flutter_test.dart';

MediaState media({
  bool bt = true,
  bool wifi = true,
  bool loc = true,
  bool airplane = false,
}) =>
    MediaState(bluetooth: bt, wifi: wifi, location: loc, airplane: airplane);

void main() {
  group('MeshRecoveryPolicy - reglas de medios', () {
    late MeshRecoveryPolicy policy;

    setUp(() {
      policy = MeshRecoveryPolicy();
    });

    MediaDecision decide({
      bool wants = true,
      bool running = true,
      int connected = 1,
    }) =>
        policy.decide(
          userWantsMesh: wants,
          running: running,
          connectedCount: connected,
        );

    test('sin intención del usuario nunca actúa', () {
      policy.onMediaEvent(media(bt: false, wifi: false));
      expect(decide(wants: false), MediaDecision.none);
    });

    test('sin snapshot: inicia si no está en marcha, si no no hace nada', () {
      expect(decide(running: false), MediaDecision.start);
      expect(decide(running: true), MediaDecision.none);
    });

    test('Bluetooth y Wi-Fi apagados pausa por noMedia', () {
      policy.onMediaEvent(media(bt: false, wifi: false));
      expect(decide(), MediaDecision.pauseNoMedia);
    });

    test('el modo avión por sí solo no cuenta como todo apagado', () {
      policy.onMediaEvent(media(wifi: false, airplane: true));
      expect(decide(running: false), MediaDecision.start);
    });

    test('ubicación apagada solo pausa el discovery', () {
      policy.onMediaEvent(media(loc: false));
      expect(decide(), MediaDecision.pauseDiscovery);
    });

    test('ubicación apagada con Nearby detenido también queda pausada', () {
      policy.onMediaEvent(media(loc: false));
      expect(decide(running: false), MediaDecision.pauseDiscovery);
    });

    test('vuelve la ubicación estando en marcha: reinicio suave', () {
      policy.onMediaEvent(media(loc: false));
      decide();
      policy.onMediaEvent(media());
      expect(decide(), MediaDecision.softRestart);
    });

    test('vuelve algún medio estando en noMedia: inicia', () {
      policy.onMediaEvent(media(bt: false, wifi: false));
      expect(decide(), MediaDecision.pauseNoMedia);
      policy.onMediaEvent(media(wifi: false));
      expect(decide(running: false), MediaDecision.start);
    });

    test('Bluetooth pasó por OFF y volvió: reinicio completo, una sola vez', () {
      policy.onMediaEvent(media(wifi: false, airplane: true));
      decide(); // baseline
      policy.onMediaEvent(media(bt: false, wifi: false, airplane: true));
      policy.onMediaEvent(media(wifi: false, airplane: true));
      expect(decide(), MediaDecision.fullRestart);
      expect(decide(), MediaDecision.none);
    });

    test('Bluetooth aún apagado con Wi-Fi: no hace reinicio completo', () {
      policy.onMediaEvent(media());
      decide();
      policy.onMediaEvent(media(bt: false));
      expect(decide(), MediaDecision.softRestart);
      policy.onMediaEvent(media());
      expect(decide(), MediaDecision.fullRestart);
    });

    test('modo avión sin Bluetooth reiniciado y sin vecinos: reinicio completo', () {
      // Android moderno mantiene el Bluetooth encendido en modo avión: no hay
      // paso por OFF, pero los enlaces cayeron con el Wi-Fi.
      policy.onMediaEvent(media());
      decide();
      policy.onMediaEvent(media(wifi: false, airplane: true));
      expect(decide(connected: 0), MediaDecision.fullRestart);
    });

    test('solo cambió el Wi-Fi: reinicio suave que preserva enlaces', () {
      policy.onMediaEvent(media());
      decide();
      policy.onMediaEvent(media(wifi: false));
      expect(decide(), MediaDecision.softRestart);
    });

    test('mismo snapshot repetido (ej. al volver a primer plano): no hace nada', () {
      policy.onMediaEvent(media());
      expect(decide(running: false), MediaDecision.start);
      policy.onMediaEvent(media());
      expect(decide(), MediaDecision.none);
    });

    test('canDiscover refleja la ubicación', () {
      expect(policy.canDiscover, isTrue);
      policy.onMediaEvent(media(loc: false));
      expect(policy.canDiscover, isFalse);
    });
  });

  group('MeshRecoveryPolicy - control de seguridad', () {
    late MeshRecoveryPolicy policy;

    setUp(() {
      policy = MeshRecoveryPolicy();
    });

    test('con vecinos conectados no hace nada', () {
      expect(policy.onSafetyTick(connectedCount: 2), SafetyAction.none);
    });

    test('sin vecinos reinicia el discovery', () {
      expect(policy.onSafetyTick(connectedCount: 0), SafetyAction.restartDiscovery);
    });

    test('3 controles seguidos sin hallazgos reinician también el advertising', () {
      expect(policy.onSafetyTick(connectedCount: 0), SafetyAction.restartDiscovery);
      expect(policy.onSafetyTick(connectedCount: 0), SafetyAction.restartDiscovery);
      expect(
        policy.onSafetyTick(connectedCount: 0),
        SafetyAction.restartDiscoveryAndAdvertising,
      );
      expect(policy.onSafetyTick(connectedCount: 0), SafetyAction.restartDiscovery);
    });

    test('un onEndpointFound reinicia la cuenta', () {
      policy.onSafetyTick(connectedCount: 0);
      policy.onSafetyTick(connectedCount: 0);
      policy.onEndpointFound();
      expect(policy.onSafetyTick(connectedCount: 0), SafetyAction.restartDiscovery);
    });

    test('tener vecinos reinicia la cuenta', () {
      policy.onSafetyTick(connectedCount: 0);
      policy.onSafetyTick(connectedCount: 0);
      policy.onSafetyTick(connectedCount: 1);
      expect(policy.onSafetyTick(connectedCount: 0), SafetyAction.restartDiscovery);
    });
  });

  group('MeshRecoveryPolicy - reconexión y bloqueo', () {
    test('tras una caída el mayor espera la ventana de pérdida (2 s)', () {
      expect(
        MeshRecoveryPolicy.reconnectDelay('b', 'a'),
        MeshRecoveryPolicy.lostGracePeriod,
      );
      expect(MeshRecoveryPolicy.lostGracePeriod, const Duration(seconds: 2));
    });

    test('tras una caída el menor espera el fallback (8 s)', () {
      expect(
        MeshRecoveryPolicy.reconnectDelay('a', 'b'),
        MeshRecoveryPolicy.initiatorFallbackDelay,
      );
    });

    test('bloqueo temporal: bloquear, consultar y limpiar', () {
      final policy = MeshRecoveryPolicy();
      expect(policy.isBlocked('x'), isFalse);
      policy.blockNode('x');
      expect(policy.isBlocked('x'), isTrue);
      expect(policy.isBlocked('y'), isFalse);
      policy.clearBlocks();
      expect(policy.isBlocked('x'), isFalse);
    });
  });

  group('MeshRecoveryPolicy - iniciador', () {
    test('el ID mayor es el iniciador primario', () {
      expect(MeshRecoveryPolicy.isPrimaryInitiator('b', 'a'), isTrue);
      expect(MeshRecoveryPolicy.isPrimaryInitiator('a', 'b'), isFalse);
      expect(MeshRecoveryPolicy.isPrimaryInitiator('a', 'a'), isFalse);
    });

    test('el fallback espera 8 s', () {
      expect(MeshRecoveryPolicy.initiatorFallbackDelay, const Duration(seconds: 8));
    });
  });
}
