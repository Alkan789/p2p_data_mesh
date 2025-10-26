// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/emergency_protocol.dart' as emergency;
import 'services/platform_ble.dart' as platform_ble;
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String logText = '';
  Timer? pollTimer;
  StreamSubscription<dynamic>? scanSub;
  List<Map<String, dynamic>> neighbors = [];
  bool scanning = false;

  @override
  void initState() {
    super.initState();
    final deviceId = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      emergency.protocolInit(deviceId);
      _appendLog('Protocol init with id $deviceId');
    } catch (e) {
      _appendLog('protocolInit exception: $e');
    }
    _startPollLoop();
    _listenScanStream();
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    scanSub?.cancel();
    super.dispose();
  }

  void _appendLog(String s) {
    setState(() {
      logText = '${DateTime.now().toIso8601String()} - $s\n$logText';
    });
    // ignore: avoid_print
    print(s);
  }

  Future<bool> _requestPermissions() async {
    _appendLog("Requesting permissions...");

    final List<Permission> perms = [];

    if (Platform.isAndroid) {
      perms.add(Permission.locationWhenInUse);
      // Android 12+ explicit BLE perms (permission_handler may not expose constants on old versions)
      try {
        perms.add(Permission.bluetoothScan);
        perms.add(Permission.bluetoothConnect);
        perms.add(Permission.bluetoothAdvertise);
      } catch (e) {
        _appendLog('Bluetooth permission constants not available: $e');
      }
    } else if (Platform.isIOS) {
      perms.add(Permission.locationWhenInUse);
      perms.add(Permission.bluetooth);
    }

    // Check before
    final Map<Permission, PermissionStatus> before = {};
    for (final p in perms) {
      before[p] = await p.status;
    }
    _appendLog('Before request statuses: ${before.entries.map((e) => "${e.key}: ${e.value}").join(", ")}');

    // Request
    final Map<Permission, PermissionStatus> statuses = await perms.request();
    _appendLog('After request statuses: ${statuses.entries.map((e) => "${e.key}: ${e.value}").join(", ")}');

    final anyPermanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
    if (anyPermanentlyDenied) {
      final ok = await _showSettingsDialog();
      if (ok) {
        openAppSettings();
        return false;
      }
      return false;
    }

    final allGranted = statuses.values.every((s) => s.isGranted || s.isLimited);
    if (!allGranted) {
      // fallback to platform native request (MainActivity.ensurePermissions)
      try {
        final platformOk = await platform_ble.PlatformBle.requestPlatformPermissions();
        _appendLog('Platform permission bridge result: $platformOk');
        return platformOk;
      } catch (e) {
        _appendLog('Platform permission bridge threw: $e');
      }
    }

    _appendLog('Permissions result -> allGranted: $allGranted');
    return allGranted;
  }

  Future<bool> _showSettingsDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Permissions required'),
            content: const Text('Uygulama düzgün çalışması için izinlere ihtiyaç duyuyor. Ayarlardan izinleri verin.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Vazgeç')),
              TextButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Ayarlar')),
            ],
          ),
        ) ??
        false;
  }

  void _listenScanStream() {
    scanSub = platform_ble.PlatformBle.scanStream.listen(
      (event) {
        try {
          final Map obj = Map<String, dynamic>.from(event as Map);
          final data = obj['bytes'];
          final rssi = obj['rssi'] ?? 0;
          final addr = obj['addr'] ?? '';
          final name = obj['name'] ?? '';

          if (data is Uint8List) {
            try {
              emergency.receiveRaw(data, rssi as int, addr as String);
            } catch (e) {
              _appendLog('receiveRaw threw: $e');
            }
            _appendLog('Scan -> raw ${data.length} bytes from $addr rssi:$rssi name:$name');
          } else if (data is List<int>) {
            final u = Uint8List.fromList(List<int>.from(data));
            try {
              emergency.receiveRaw(u, rssi as int, addr as String);
            } catch (e) {
              _appendLog('receiveRaw threw: $e');
            }
            _appendLog('Scan(list) -> raw ${u.length} bytes from $addr rssi:$rssi name:$name');
          } else {
            _appendLog('Scan event with unknown bytes format: ${data.runtimeType}');
          }
        } catch (e) {
          _appendLog('Scan stream error: $e');
        }
      },
      onError: (err) {
        _appendLog('Scan stream failed: $err');
      },
    );
  }

  void _startPollLoop() {
    pollTimer = Timer.periodic(const Duration(milliseconds: 400), (t) {
      try {
        Uint8List? pkt;
        try {
          pkt = emergency.pollIncoming();
        } catch (e) {
          _appendLog('pollIncoming threw: $e');
          pkt = null;
        }
        if (pkt != null && pkt.isNotEmpty) {
          _appendLog('Incoming packet raw ${pkt.length} bytes');
        }
        String json = '';
        try {
          json = emergency.getNeighborsJson();
        } catch (e) {
          _appendLog('getNeighborsJson threw: $e');
          json = '';
        }
        if (json.isNotEmpty) {
          final parsed = jsonDecode(json) as List<dynamic>;
          setState(() {
            neighbors = parsed.map((e) => Map<String, dynamic>.from(e)).toList();
          });
        }
      } catch (e) {
        _appendLog('Poll loop error: $e');
      }
    });
  }

  Future<void> _onInitProtocol() async {
    final did = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      emergency.protocolInit(did);
      _appendLog('Protocol init with id $did');
    } catch (e) {
      _appendLog('protocolInit error: $e');
    }
  }

  Future<void> _onSendBroadcast() async {
    final text = 'HELLO ${DateTime.now().toIso8601String()}';
    try {
      final r = emergency.sendBroadcast(text);
      _appendLog('Sendbroadcast Result: $r');
    } catch (e) {
      _appendLog('sendBroadcast error: $e');
    }
  }

  Future<void> _onStartScan() async {
    final permOk = await _requestPermissions();
    _appendLog('Permissions Granted: $permOk');
    if (!permOk) {
      _appendLog('Permissions Not Granted');
      return;
    }
    try {
      final ok = await platform_ble.PlatformBle.startScan();
      setState(() => scanning = ok);
      _appendLog('StartScan Requested -> $ok');
    } catch (e) {
      _appendLog('startScan platform call threw: $e');
    }
  }

  Future<void> _onStopScan() async {
    try {
      final ok = await platform_ble.PlatformBle.stopScan();
      setState(() => scanning = ok ? false : scanning);
      _appendLog('Stopscan Requested -> $ok');
    } catch (e) {
      _appendLog('stopScan platform call threw: $e');
    }
  }

  Future<void> _onStartAdvertise() async {
    final permOk = await _requestPermissions();
    if (!permOk) {
      _appendLog('Permissions Not Granted for advertise');
      return;
    }
    try {
      final ok = await platform_ble.PlatformBle.startAdvertise();
      _appendLog('StartAdvertise -> $ok');
    } catch (e) {
      _appendLog('startAdvertise platform call threw: $e');
    }
  }

  Future<void> _onStopAdvertise() async {
    try {
      final ok = await platform_ble.PlatformBle.stopAdvertise();
      _appendLog('StopAdvertise -> $ok');
    } catch (e) {
      _appendLog('stopAdvertise platform call threw: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P Emergency Mesh',
      home: Scaffold(
        appBar: AppBar(title: const Text('P2P Emergency Mesh')),
        body: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(onPressed: _onInitProtocol, child: const Text('Init Protocol')),
                  ElevatedButton(onPressed: _onSendBroadcast, child: const Text('Send Broadcast')),
                  ElevatedButton(onPressed: _onStartScan, child: const Text('Start Scan')),
                  ElevatedButton(onPressed: _onStopScan, child: const Text('Stop Scan')),
                  ElevatedButton(onPressed: _onStartAdvertise, child: const Text('Start Advertise')),
                  ElevatedButton(onPressed: _onStopAdvertise, child: const Text('Stop Advertise')),
                ],
              ),
              const SizedBox(height: 8),
              Text('Scanning: $scanning'),
              const SizedBox(height: 8),
              Text('Neighbors (${neighbors.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(
                child: ListView.builder(
                  itemCount: neighbors.length,
                  itemBuilder: (c, i) {
                    final n = neighbors[i];
                    return ListTile(
                      title: Text(n['device_id'] ?? '<unknown>'),
                      subtitle: Text('addr: ${n['address'] ?? ''}  rssi:${n['rssi'] ?? ''}'),
                      trailing: Text('${n['last_seen'] ?? ''}'),
                    );
                  },
                ),
              ),
              const Divider(),
              Expanded(child: SingleChildScrollView(reverse: true, child: Text(logText))),
            ],
          ),
        ),
      ),
    );
  }
}
