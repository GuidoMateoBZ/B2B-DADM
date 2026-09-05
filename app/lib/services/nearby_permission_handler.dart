import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<bool> requestNearbyPermissions() async {
    final statuses = await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
    ].request();

    return statuses.values.every((s) => s.isGranted);
  }
}
