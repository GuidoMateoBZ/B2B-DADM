package com.b2b.media_state

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
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Canales de estado de medios. Como plugin se registra en todos los engines,
 * también en el del servicio de fondo, que así recibe los cambios con la app
 * cerrada. Cada engine tiene su propia instancia y su propio receiver.
 */
class MediaStatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private var queryChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var receiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        queryChannel = MethodChannel(binding.binaryMessenger, QUERY_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        unregisterReceiver()
        queryChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        queryChannel = null
        eventChannel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "getState") result.success(readMediaState())
        else result.notImplemented()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        unregisterReceiver()
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
            context.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(r, filter)
        }
        receiver = r
        events.success(readMediaState())
    }

    override fun onCancel(arguments: Any?) {
        unregisterReceiver()
    }

    private fun unregisterReceiver() {
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Ya estaba dado de baja.
            }
        }
        receiver = null
    }

    /**
     * Snapshot completo. Las radios se informan como "on", "off" o "transitioning"
     * (TURNING_ON/TURNING_OFF, ENABLING/DISABLING) para que Dart no decida en
     * medio de un cambio.
     */
    private fun readMediaState(): Map<String, Any> {
        val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val bluetooth = when (btManager?.adapter?.state) {
            BluetoothAdapter.STATE_ON -> "on"
            BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> "transitioning"
            else -> "off"
        }

        val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val wifi = when (wifiManager?.wifiState) {
            WifiManager.WIFI_STATE_ENABLED -> "on"
            WifiManager.WIFI_STATE_ENABLING, WifiManager.WIFI_STATE_DISABLING -> "transitioning"
            else -> "off"
        }

        val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val location = if (locationManager == null) {
            false
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locationManager.isLocationEnabled
        } else {
            locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }

        val airplane = Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0

        return mapOf(
            "bluetooth" to bluetooth,
            "wifi" to wifi,
            "location" to location,
            "airplane" to airplane,
        )
    }

    companion object {
        private const val EVENT_CHANNEL = "com.b2b.dadm/media_state"
        private const val QUERY_CHANNEL = "com.b2b.dadm/media_state_query"
    }
}
