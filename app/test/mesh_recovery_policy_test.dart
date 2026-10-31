import 'package:app/data/models/media_state.dart';
import 'package:app/services/mesh_recovery_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const on = RadioState.on;
const off = RadioState.off;
const moving = RadioState.transitioning;

MediaState media({
  RadioState bt = on,
  RadioState wifi = on,
  bool loc = true,
  bool airplane = false,
}) =>
    MediaState(bluetooth: bt, wifi: wifi, location: loc, airplane: airplane);

void main() {
  group('MediaState', () {
    test('parsea los tres estados de radio desde el canal nativo', () {
      final m = MediaState.fromMap({
        'bluetooth': 'transitioning',
        'wifi': 'on',
        'location': true,
        'airplane': false,
      });
      expect(m.bluetooth, moving);
      expect(m.wifi, on);
      expect(m.stable, isFalse);
      expect(media(bt: off, wifi: off).noTransport, isTrue);
      expect(media(bt: moving, wifi: off).noTransport, isTrue);
    });
  });

  group('MeshRecoveryPolicy - máquina de estados', () {
    late MeshRecoveryPolicy policy;

    setUp(() {
      policy = MeshRecoveryPolicy();
    });

    /// Lleva la máquina a `running` con [initial] como último estado aplicado.
    void startRunning([MediaState? initial]) {
      policy.onMediaEvent(initial ?? media());
      expect(policy.connect(), MeshAction.start);
      expect(policy.state, MeshState.running);
    }

    MeshAction stable(MediaState m, {int connected = 1}) {
      policy.onMediaEvent(m);
      return policy.onMediaStable(connectedCount: connected);
    }

    test('en idle los medios no generan acciones', () {
      expect(stable(media(bt: off, wifi: off)), MeshAction.none);
      expect(policy.state, MeshState.idle);
    });

    test('Conectar sin snapshot inicia en running', () {
      expect(policy.connect(), MeshAction.start);
      expect(policy.state, MeshState.running);
    });

    test('Conectar sin medios queda en pausedNoMedia sin acción', () {
      policy.onMediaEvent(media(bt: off, wifi: off));
      expect(policy.connect(), MeshAction.none);
      expect(policy.state, MeshState.pausedNoMedia);
    });

    test('Conectar sin ubicación inicia solo advertising', () {
      policy.onMediaEvent(media(loc: false));
      expect(policy.connect(), MeshAction.start);
      expect(policy.state, MeshState.runningNoDiscovery);
      expect(policy.discoveryActive, isFalse);
    });

    test('Desconectar vuelve a idle', () {
      startRunning();
      policy.disconnect();
      expect(policy.state, MeshState.idle);
    });

    test('si el inicio falla vuelve a idle', () {
      startRunning();
      policy.onStartFailed();
      expect(policy.state, MeshState.idle);
    });

    test('running sin medios pausa con un único stopAll (idempotente)', () {
      startRunning();
      expect(stable(media(bt: off, wifi: off, airplane: true)), MeshAction.pause);
      expect(policy.state, MeshState.pausedNoMedia);
      // Volver de la cortina con el mismo snapshot, o cambiar solo el modo avión.
      expect(stable(media(bt: off, wifi: off, airplane: true)), MeshAction.none);
      expect(stable(media(bt: off, wifi: off)), MeshAction.none);
      expect(policy.state, MeshState.pausedNoMedia);
    });

    test('con radios en transición no se decide', () {
      startRunning();
      expect(stable(media(bt: moving, wifi: off)), MeshAction.none);
      expect(policy.state, MeshState.running);
    });

    test('pausedNoMedia: vuelve un medio estable -> start', () {
      startRunning();
      stable(media(bt: off, wifi: off));
      expect(stable(media(bt: moving, wifi: off)), MeshAction.none);
      expect(stable(media(bt: on, wifi: off)), MeshAction.start);
      expect(policy.state, MeshState.running);
    });

    test('pausedNoMedia: vuelve un medio sin ubicación -> start sin discovery', () {
      startRunning();
      stable(media(bt: off, wifi: off));
      expect(stable(media(wifi: off, loc: false)), MeshAction.start);
      expect(policy.state, MeshState.runningNoDiscovery);
    });

    test('Wi-Fi vuelve antes que el Bluetooth: un start y un solo reinicio al estabilizarse', () {
      startRunning();
      stable(media(bt: off, wifi: off));
      expect(stable(media(bt: off, wifi: on)), MeshAction.start);
      // El Bluetooth arranca después: TURNING_ON no cuenta como caída.
      expect(stable(media(bt: moving, wifi: on), connected: 0), MeshAction.none);
      expect(stable(media(bt: on, wifi: on), connected: 0), MeshAction.fullRestart);
      expect(stable(media(bt: on, wifi: on), connected: 0), MeshAction.none);
    });

    test('el Bluetooth cae y vuelve en marcha (modo avión viejo): reinicio completo', () {
      startRunning(media(wifi: off));
      policy.onMediaEvent(media(bt: moving, wifi: off, airplane: true));
      policy.onMediaEvent(media(bt: off, wifi: off, airplane: true));
      policy.onMediaEvent(media(bt: moving, wifi: off, airplane: true));
      expect(
        stable(media(bt: on, wifi: off, airplane: true), connected: 2),
        MeshAction.fullRestart,
      );
      expect(stable(media(bt: on, wifi: off, airplane: true)), MeshAction.none);
    });

    test('modo avión con Bluetooth encendido: sin vecinos reinicio completo', () {
      startRunning();
      expect(stable(media(wifi: off, airplane: true), connected: 0), MeshAction.fullRestart);
    });

    test('solo cambió el Wi-Fi con vecinos: reinicio suave', () {
      startRunning();
      expect(stable(media(wifi: off), connected: 1), MeshAction.softRestart);
      expect(policy.state, MeshState.running);
    });

    test('mismo snapshot repetido en running: nada', () {
      startRunning();
      expect(stable(media()), MeshAction.none);
    });

    test('ubicación: running -> runningNoDiscovery -> running', () {
      startRunning();
      expect(stable(media(loc: false)), MeshAction.stopDiscovery);
      expect(policy.state, MeshState.runningNoDiscovery);
      expect(stable(media(loc: false)), MeshAction.none);
      expect(stable(media()), MeshAction.startDiscovery);
      expect(policy.state, MeshState.running);
    });

    test('runningNoDiscovery sin medios -> pausa', () {
      startRunning();
      stable(media(loc: false));
      expect(stable(media(bt: off, wifi: off, loc: false)), MeshAction.pause);
      expect(policy.state, MeshState.pausedNoMedia);
    });

    test('caída del Bluetooth sin ubicación: reinicio completo sin discovery', () {
      startRunning();
      stable(media(loc: false));
      policy.onMediaEvent(media(bt: off, loc: false));
      expect(stable(media(loc: false)), MeshAction.fullRestart);
      expect(policy.state, MeshState.runningNoDiscovery);
      expect(stable(media()), MeshAction.startDiscovery);
    });

    test('vuelven a la vez el Bluetooth y la ubicación: reinicio completo', () {
      startRunning();
      stable(media(loc: false));
      policy.onMediaEvent(media(bt: off, wifi: on, loc: false));
      expect(stable(media(bt: off, wifi: on, loc: false), connected: 1), MeshAction.softRestart);
      expect(stable(media()), MeshAction.fullRestart);
      expect(policy.state, MeshState.running);
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
