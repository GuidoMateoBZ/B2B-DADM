package com.b2b.b2b

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var receiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "com.b2b.dadm/media_state_query").setMethodCallHandler { call, result ->
            if (call.method == "getState") result.success(readMediaState())
            else result.notImplemented()
        }

        EventChannel(messenger, "com.b2b.dadm/media_state").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val r = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            events.success(readMediaState())
                        }
                    }
                    val filter = IntentFilter().apply {
                        addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                        addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
                        addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
                        addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        applicationContext.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        applicationContext.registerReceiver(r, filter)
                    }
                    receiver = r
                    events.success(readMediaState())
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let { applicationContext.unregisterReceiver(it) }
                    receiver = null
                }
            }
        )
    }

    /**
     * Snapshot completo. Las radios se informan como "on", "off" o "transitioning"
     * (TURNING_ON/TURNING_OFF, ENABLING/DISABLING) para que Dart no decida en
     * medio de un cambio.
     */
    private fun readMediaState(): Map<String, Any> {
        val ctx = applicationContext
        val btManager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val bluetooth = when (btManager?.adapter?.state) {
            BluetoothAdapter.STATE_ON -> "on"
            BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> "transitioning"
            else -> "off"
        }

        val wifiManager = ctx.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val wifi = when (wifiManager?.wifiState) {
            WifiManager.WIFI_STATE_ENABLED -> "on"
            WifiManager.WIFI_STATE_ENABLING, WifiManager.WIFI_STATE_DISABLING -> "transitioning"
            else -> "off"
        }

        val locationManager = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val location = if (locationManager == null) {
            false
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locationManager.isLocationEnabled
        } else {
            locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }

        val airplane = Settings.Global.getInt(ctx.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0

        return mapOf(
            "bluetooth" to bluetooth,
            "wifi" to wifi,
            "location" to location,
            "airplane" to airplane,
        )
    }

    override fun onDestroy() {
        receiver?.let { applicationContext.unregisterReceiver(it) }
        receiver = null
        super.onDestroy()
    }
}
