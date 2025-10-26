// lib/services/emergency_protocol.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

final DynamicLibrary _nativeLib = () {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libemergency_protocol.so');
  } else if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  throw UnsupportedError('Platform not supported');
}();

//
// C typedefs (matching emergency_protocol.h)
//
typedef C_emergency_protocol_init = Void Function(Pointer<Utf8> self_id);
typedef C_emergency_send_broadcast = Int32 Function(Pointer<Utf8> message);
typedef C_emergency_receive_raw =
    Int32 Function(
      Pointer<Uint8> raw,
      Uint32 raw_len,
      Int32 rssi,
      Pointer<Utf8> remote_addr,
    );
typedef C_emergency_poll_incoming =
    Int32 Function(Pointer<Uint8> out_buf, Uint32 max_len);
typedef C_emergency_get_neighbors_json =
    Int32 Function(Pointer<Uint8> out_buf, Uint32 max_len);

//
// Dart typedefs
//
typedef Dart_emergency_protocol_init = void Function(Pointer<Utf8> self_id);
typedef Dart_emergency_send_broadcast = int Function(Pointer<Utf8> message);
typedef Dart_emergency_receive_raw =
    int Function(
      Pointer<Uint8> raw,
      int raw_len,
      int rssi,
      Pointer<Utf8> remote_addr,
    );
typedef Dart_emergency_poll_incoming =
    int Function(Pointer<Uint8> out_buf, int max_len);
typedef Dart_emergency_get_neighbors_json =
    int Function(Pointer<Uint8> out_buf, int max_len);

//
// Lookups
//
final Dart_emergency_protocol_init _c_protocol_init = _nativeLib
    .lookup<NativeFunction<C_emergency_protocol_init>>(
      'emergency_protocol_init',
    )
    .asFunction();

final Dart_emergency_send_broadcast _c_send_broadcast = _nativeLib
    .lookup<NativeFunction<C_emergency_send_broadcast>>(
      'emergency_send_broadcast',
    )
    .asFunction();

final Dart_emergency_receive_raw _c_receive_raw = _nativeLib
    .lookup<NativeFunction<C_emergency_receive_raw>>('emergency_receive_raw')
    .asFunction();

final Dart_emergency_poll_incoming _c_poll_incoming = _nativeLib
    .lookup<NativeFunction<C_emergency_poll_incoming>>(
      'emergency_poll_incoming',
    )
    .asFunction();

final Dart_emergency_get_neighbors_json _c_get_neighbors_json = _nativeLib
    .lookup<NativeFunction<C_emergency_get_neighbors_json>>(
      'emergency_get_neighbors_json',
    )
    .asFunction();

//
// Dart-friendly wrappers (kullanacağın isimler main.dart ile uyumlu)
//

/// Initialize the C core with a device id string.
void protocolInit(String selfDeviceId) {
  final ptr = selfDeviceId.toNativeUtf8();
  try {
    _c_protocol_init(ptr);
  } finally {
    calloc.free(ptr);
  }
}

/// Send a broadcast message (simple text). Returns C int (0 = ok).
int sendBroadcast(String message) {
  final ptr = message.toNativeUtf8();
  try {
    return _c_send_broadcast(ptr);
  } finally {
    calloc.free(ptr);
  }
}

/// Feed incoming raw bytes from platform (scan). Returns int status from C.
int receiveRaw(Uint8List raw, int rssi, String remoteAddr) {
  final len = raw.length;
  final Pointer<Uint8> buf = calloc<Uint8>(len);
  try {
    final asList = buf.asTypedList(len);
    asList.setAll(0, raw);
    final addrPtr = remoteAddr.toNativeUtf8();
    try {
      return _c_receive_raw(buf, len, rssi, addrPtr);
    } finally {
      calloc.free(addrPtr);
    }
  } finally {
    calloc.free(buf);
  }
}

/// Poll for an outgoing application packet. Returns Uint8List or null.
/// Default maxLen tuned (adjust if needed).
Uint8List? pollIncoming({int maxLen = 2048}) {
  final Pointer<Uint8> outBuf = calloc<Uint8>(maxLen);
  try {
    final got = _c_poll_incoming(outBuf, maxLen);
    if (got <= 0) return null;
    final typed = outBuf.asTypedList(got);
    return Uint8List.fromList(typed);
  } finally {
    calloc.free(outBuf);
  }
}

/// Get neighbors list as JSON string. Returns empty string if none or on error.
String getNeighborsJson({int maxLen = 8192}) {
  final Pointer<Uint8> outBuf = calloc<Uint8>(maxLen);
  try {
    final got = _c_get_neighbors_json(outBuf, maxLen);
    if (got <= 0) return '';
    // ensure we read as Utf8 C-string
    final ptr = outBuf.cast<Utf8>();
    final s = ptr.toDartString();
    return s;
  } finally {
    calloc.free(outBuf);
  }
}
