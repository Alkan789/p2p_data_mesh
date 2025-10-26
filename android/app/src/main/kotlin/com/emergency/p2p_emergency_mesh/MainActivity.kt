package com.emergency.p2p_emergency_mesh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.util.Log

class MainActivity: FlutterActivity() {
    private val TAG = "MainActivityP2P"
    private val METHOD_CHANNEL = "com.emergency.p2p/methods"
    private val EVENT_CHANNEL = "com.emergency.p2p/events"
    private var eventSink: EventChannel.EventSink? = null
    private var isScanning = false

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        BluetoothAdapter.getDefaultAdapter()
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            try {
                val record = result.scanRecord?.bytes
                val addr = result.device.address ?: ""
                val name = result.device.name ?: ""
                val rssi = result.rssi
                val map: MutableMap<String, Any> = HashMap()
                if (record != null) {
                    map["bytes"] = record
                } else {
                    map["bytes"] = ByteArray(0)
                }
                map["rssi"] = rssi
                map["addr"] = addr
                map["name"] = name
                eventSink?.success(map)
            } catch (e: Exception) {
                Log.e(TAG, "onScanResult error: ${e.message}")
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> {
                    val ok = startBleScan()
                    result.success(ok)
                }
                "stopScan" -> {
                    val ok = stopBleScan()
                    result.success(ok)
                }
                "startAdvertise" -> {
                    val intent = Intent(this, BleAdvertiserService::class.java).apply { action = "START" }
                    // startForegroundService için izinli ortamda çağırıyoruz; Android O+ için uyumlu
                    ContextCompat.startForegroundService(this, intent)
                    result.success(true)
                }
                "stopAdvertise" -> {
                    val intent = Intent(this, BleAdvertiserService::class.java).apply { action = "STOP" }
                    startService(intent)
                    result.success(true)
                }
                "startAdvertiseWithPayload" -> {
    val payloadBase64 = call.argument<String>("payload_base64")
    val intent = Intent(this, BleAdvertiserService::class.java).apply {
        action = "START"
        putExtra("payload_base64", payloadBase64)
    }
    ContextCompat.startForegroundService(this, intent)
    result.success(true)
}

                "hasBluetooth" -> {
                    val adapter = bluetoothAdapter
                    result.success(adapter != null && adapter.isEnabled)
                }
                "requestPlatformPermissions" -> {
                    val granted = ensurePermissions()
                    result.success(granted)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    private fun ensurePermissions(): Boolean {
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            needed.add(Manifest.permission.BLUETOOTH_SCAN)
            needed.add(Manifest.permission.BLUETOOTH_CONNECT)
            needed.add(Manifest.permission.BLUETOOTH_ADVERTISE)
        } else {
            needed.add(Manifest.permission.ACCESS_FINE_LOCATION)
            needed.add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        needed.add(Manifest.permission.ACCESS_WIFI_STATE)
        needed.add(Manifest.permission.CHANGE_WIFI_STATE)

        val notGranted = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (notGranted.isEmpty()) return true

        ActivityCompat.requestPermissions(this, notGranted.toTypedArray(), 12345)
        return false
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun startBleScan(): Boolean {
        if (isScanning) return true
        try {
            val adapter = bluetoothAdapter
            if (adapter == null) {
                Log.e(TAG, "No Bluetooth adapter")
                return false
            }
            val scanner = adapter.bluetoothLeScanner
            if (scanner == null) {
                Log.e(TAG, "Bluetooth LE scanner not available")
                return false
            }
            scanner.startScan(scanCallback)
            isScanning = true
            Log.i(TAG, "BLE scan started")
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "startBleScan SecurityException: ${e.message}")
            return false
        } catch (e: Exception) {
            Log.e(TAG, "startBleScan Exception: ${e.message}")
            return false
        }
    }

    private fun stopBleScan(): Boolean {
        if (!isScanning) return true
        try {
            val adapter = bluetoothAdapter
            val scanner = adapter?.bluetoothLeScanner
            scanner?.stopScan(scanCallback)
            isScanning = false
            Log.i(TAG, "BLE scan stopped")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "stopBleScan Exception: ${e.message}")
            return false
        }
    }
}
