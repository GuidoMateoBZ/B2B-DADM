import 'package:flutter/services.dart';

import '../data/models/media_state.dart';

/// Observa el estado de los medios (Bluetooth, Wi-Fi, ubicación, modo avión)
/// mediante un EventChannel nativo que emite un snapshot completo en cada cambio.
class MediaStateService {
  static const EventChannel _events = EventChannel('com.b2b.dadm/media_state');
  static const MethodChannel _query = MethodChannel('com.b2b.dadm/media_state_query');

  /// Emite un snapshot al suscribirse y ante cada cambio de medios.
  Stream<MediaState> get stream => _events
      .receiveBroadcastStream()
      .map((event) => MediaState.fromMap(event as Map<dynamic, dynamic>));

  /// Consulta puntual del estado actual (null si la plataforma no responde).
  Future<MediaState?> current() async {
    try {
      final map = await _query.invokeMethod<Map<dynamic, dynamic>>('getState');
      return map == null ? null : MediaState.fromMap(map);
    } catch (_) {
      return null;
    }
  }
}
