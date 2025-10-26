package com.emergency.p2p_emergency_mesh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

class BleAdvertiserService : Service() {
    private val TAG = "BleAdvertiserSvc"
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertising = false

    override fun onCreate() {
        super.onCreate()
        val adapter = BluetoothAdapter.getDefaultAdapter()
        advertiser = adapter?.bluetoothLeAdvertiser

        val channelId = "p2pmesh"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val chan = NotificationChannel(channelId, "P2P Mesh", NotificationManager.IMPORTANCE_LOW)
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(chan)
        }
        val n = NotificationCompat.Builder(this, channelId)
            .setContentTitle("P2P Mesh")
            .setContentText("Advertising for emergency mesh")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(101, n)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val action = intent?.action
    if (action == "START") {
        // payloadBase64 optional
        val payloadBase64 = intent.getStringExtra("payload_base64")
        startAdvertising(payloadBase64)
    } else if (action == "STOP") {
        stopAdvertising()
    }
    return START_STICKY
}

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            super.onStartSuccess(settingsInEffect)
            advertising = true
            Log.i(TAG, "Advertise started")
        }
        override fun onStartFailure(errorCode: Int) {
            super.onStartFailure(errorCode)
            advertising = false
            Log.e(TAG, "Advertise failed: $errorCode")
        }
    }

    private fun startAdvertising(payloadBase64: String?) {
    try {
        val adv = advertiser ?: run {
            Log.e(TAG, "No advertiser available")
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .build()

        val payloadBytes = if (payloadBase64 != null) {
            android.util.Base64.decode(payloadBase64, android.util.Base64.DEFAULT)
        } else {
            // fallback tiny payload (device model)
            ("p2p:" + android.os.Build.MODEL).take(28).toByteArray(Charsets.UTF_8)
        }

        val advData = AdvertiseData.Builder()
            .addManufacturerData(0xFFFF, payloadBytes)
            .setIncludeTxPowerLevel(false)
            .setIncludeDeviceName(false)
            .build()

        adv.startAdvertising(settings, advData, advCallback)
    } catch (e: SecurityException) {
        Log.e(TAG, "startAdvertising SecurityException: ${e.message}")
    } catch (e: Exception) {
        Log.e(TAG, "startAdvertising Exception: ${e.message}")
    }
}

    private fun stopAdvertising() {
        try {
            advertiser?.stopAdvertising(advCallback)
            advertising = false
            Log.i(TAG, "Advertise stopped")
        } catch (e: Exception) {
            Log.e(TAG, "stopAdvertising Exception: ${e.message}")
        }
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        stopAdvertising()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
