import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Resultado detallado de la verificación de permisos.
class PermissionResult {
  final bool isGranted;
  final List<String> missingPermissions;

  const PermissionResult({
    required this.isGranted,
    this.missingPermissions = const [],
  });

  String get missingMessage {
    if (missingPermissions.isEmpty) return '';
    return 'Faltan permisos requeridos: ${missingPermissions.join(', ')}';
  }
}

class PermissionService {
  /// Solicita los permisos necesarios según la versión de Android y retorna true si todos fueron concedidos.
  static Future<bool> requestNearbyPermissions() async {
    final result = await requestPermissionsDetailed();
    return result.isGranted;
  }

  /// Solicita los permisos necesarios discriminando por versión de Android (SDK int)
  /// para evitar denegaciones espurias de permisos inexistentes o deshabilitados.
  static Future<PermissionResult> requestPermissionsDetailed() async {
    if (!Platform.isAndroid) {
      return const PermissionResult(isGranted: true);
    }

    int sdkInt = 0;
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      sdkInt = androidInfo.version.sdkInt;
      debugPrint('[PermissionService] Android SDK_INT: $sdkInt');
    } catch (e) {
      debugPrint('[PermissionService] Error obteniendo sdkInt: $e');
    }

    // Lista de permisos aplicables a este dispositivo
    final List<Permission> permissionsToRequest = [];

    // Ubicación: requerida para Nearby Connections / escaneo BLE
    permissionsToRequest.add(Permission.location);

    if (sdkInt >= 31) {
      // Android 12+ (API 31+) requiere permisos específicos de Bluetooth en runtime
      permissionsToRequest.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ]);
    }

    if (sdkInt >= 33) {
      // Android 13+ (API 33+) requiere permiso explícito para dispositivos Wi-Fi cercanos
      permissionsToRequest.add(Permission.nearbyWifiDevices);
    }

    debugPrint('[PermissionService] Solicitando permisos: $permissionsToRequest');
    final statuses = await permissionsToRequest.request();

    final List<String> missing = [];

    for (final permission in permissionsToRequest) {
      final status = statuses[permission] ?? await permission.status;
      debugPrint('[PermissionService] $permission status: $status');

      final isOk = status.isGranted || status.isLimited;
      if (!isOk) {
        missing.add(_permissionToName(permission));
      }
    }

    if (missing.isNotEmpty) {
      debugPrint('[PermissionService] Permisos faltantes: $missing');
      return PermissionResult(isGranted: false, missingPermissions: missing);
    }

    // Verificar si el servicio de Ubicación (GPS) está encendido en el sistema
    try {
      final locStatus = await Permission.location.serviceStatus;
      debugPrint('[PermissionService] Ubicación (GPS) serviceStatus: $locStatus');
      if (locStatus == ServiceStatus.disabled) {
        return const PermissionResult(
          isGranted: false,
          missingPermissions: ['GPS / Ubicación desactivada en el teléfono'],
        );
      }
    } catch (e) {
      debugPrint('[PermissionService] No se pudo consultar serviceStatus de ubicación: $e');
    }

    debugPrint('[PermissionService] ¡Todos los permisos y servicios requeridos están listos!');
    return const PermissionResult(isGranted: true);
  }

  /// Abre la pantalla de ajustes de la aplicación si el usuario marcó "No volver a preguntar".
  static Future<bool> openSettings() async {
    return openAppSettings();
  }

  static String _permissionToName(Permission p) {
    if (p == Permission.location) return 'Ubicación';
    if (p == Permission.bluetoothScan) return 'Bluetooth (Escanear)';
    if (p == Permission.bluetoothAdvertise) return 'Bluetooth (Anunciar)';
    if (p == Permission.bluetoothConnect) return 'Bluetooth (Conectar)';
    if (p == Permission.nearbyWifiDevices) return 'Dispositivos Wi-Fi cercanos';
    return p.toString();
  }
}
