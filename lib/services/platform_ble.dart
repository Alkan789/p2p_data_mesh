// lib/services/platform_ble.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class PlatformBle {
  static const _method = MethodChannel('com.emergency.p2p/methods');
  static const _events = EventChannel('com.emergency.p2p/events');

  static Stream<Map<String, dynamic>> get scanStream {
    return _events.receiveBroadcastStream().map(
      (e) => Map<String, dynamic>.from(e as Map),
    );
  }

  static Future<bool> startScan() async {
    final res = await _method.invokeMethod('startScan');
    return res == true;
  }

  static Future<bool> stopScan() async {
    final res = await _method.invokeMethod('stopScan');
    return res == true;
  }

  static Future<bool> startAdvertise() async {
    final res = await _method.invokeMethod('startAdvertise');
    return res == true;
  }

  static Future<bool> stopAdvertise() async {
    final res = await _method.invokeMethod('stopAdvertise');
    return res == true;
  }

  static Future<bool> startAdvertiseWithPayload(Uint8List payload) async {
  try {
    final base64 = base64Encode(payload);
    final res = await _method.invokeMethod('startAdvertiseWithPayload', {'payload_base64': base64});
    return res == true;
  } catch (e) {
    return false;
  }
}


  static Future<bool> requestPlatformPermissions() async {
    try {
      final res = await _method.invokeMethod('requestPlatformPermissions');
      return res == true;
    } catch (e) {
      return false;
    }
  }
}
