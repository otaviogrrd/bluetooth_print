import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

import 'bluetooth_print_model.dart';

enum BluetoothPrintConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class BluetoothPrintException implements Exception {
  const BluetoothPrintException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  factory BluetoothPrintException.fromPlatformException(PlatformException error) {
    return BluetoothPrintException(error.code, error.message ?? 'Bluetooth operation failed.', error.details);
  }

  @override
  String toString() => 'BluetoothPrintException($code): $message';
}

class BluetoothPrint {
  static const String NAMESPACE = 'bluetooth_print';
  static const int CONNECTED = 1;
  static const int DISCONNECTED = 0;
  static const int CONNECTING = 2;

  static const MethodChannel _channel = const MethodChannel('$NAMESPACE/methods');
  static const EventChannel _stateChannel = const EventChannel('$NAMESPACE/state');

  Stream<MethodCall> get _methodStream => _methodStreamController.stream;
  final StreamController<MethodCall> _methodStreamController = StreamController.broadcast();

  BluetoothPrint._() {
    _channel.setMethodCallHandler((MethodCall call) async {
      _methodStreamController.add(call);
    });
  }

  static final BluetoothPrint _instance = BluetoothPrint._();

  static BluetoothPrint get instance => _instance;

  Future<bool> get isAvailable async => _invoke<bool>('isAvailable').then((value) => value ?? false);

  Future<bool> get isOn async => _invoke<bool>('isOn').then((value) => value ?? false);

  Future<bool?> get isConnected async => _invoke<bool>('isConnected');

  BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);

  Stream<bool> get isScanning => _isScanning.stream;

  BehaviorSubject<List<BluetoothDevice>> _scanResults = BehaviorSubject.seeded([]);

  Stream<List<BluetoothDevice>> get scanResults => _scanResults.stream;

  PublishSubject _stopScanPill = new PublishSubject();
  Stream<int>? _stateStream;

  /// Gets the current state of the Bluetooth module
  Stream<int> _buildStateStream() async* {
    yield await _invoke<int>('state').then((s) => s ?? DISCONNECTED);

    yield* _stateChannel.receiveBroadcastStream().map((s) => s is int ? s : DISCONNECTED);
  }

  Stream<int> get state {
    _stateStream ??= _buildStateStream().asBroadcastStream();
    return _stateStream!;
  }

  /// Starts a scan for Bluetooth Low Energy devices
  /// Timeout closes the stream after a specified [Duration]
  Stream<BluetoothDevice> scan({
    Duration? timeout,
  }) async* {
    if (_isScanning.value == true) {
      throw Exception('Another scan is already in progress.');
    }

    // Emit to isScanning
    _isScanning.add(true);

    final killStreams = <Stream>[];
    killStreams.add(_stopScanPill);
    if (timeout != null) {
      killStreams.add(Rx.timer(null, timeout));
    }

    // Clear scan results list
    _scanResults.add(<BluetoothDevice>[]);

    try {
      await _invoke('startScan');
    } catch (e) {
      _stopScanPill.add(null);
      _isScanning.add(false);
      rethrow;
    }

    yield* BluetoothPrint.instance._methodStream
        .where((m) => m.method == "ScanResult")
        .map((m) => m.arguments)
        .takeUntil(Rx.merge(killStreams))
        .doOnDone(stopScan)
        .map((map) {
      final device = BluetoothDevice.fromJson(Map<String, dynamic>.from(map));
      final List<BluetoothDevice> list = _scanResults.value;
      int newIndex = -1;
      list.asMap().forEach((index, e) {
        if (e.address == device.address) {
          newIndex = index;
        }
      });

      if (newIndex != -1) {
        list[newIndex] = device;
      } else {
        list.add(device);
      }
      _scanResults.add(list);
      return device;
    });
  }

  Future startScan({
    Duration? timeout,
  }) async {
    await scan(timeout: timeout).drain();
    return _scanResults.value;
  }

  /// Stops a scan for Bluetooth Low Energy devices
  Future stopScan() async {
    await _invoke('stopScan');
    _stopScanPill.add(null);
    _isScanning.add(false);
  }

  Future<void> init() async {
    await isAvailable;
  }

  Future<dynamic> connect(BluetoothDevice device) => _invoke('connect', device.toJson());

  Future<dynamic> disconnect() => _invoke('disconnect');

  Future<dynamic> destroy() => _invoke('destroy');

  Future<BluetoothPrintConnectionState> getConnectionState() async {
    final connected = await isConnected ?? false;
    return connected ? BluetoothPrintConnectionState.connected : BluetoothPrintConnectionState.disconnected;
  }

  Future<dynamic> printReceipt(Map<String, dynamic> config, List<LineText> data) {
    Map<String, Object> args = Map();
    args['config'] = config;
    args['data'] = data.map((m) {
      return m.toJson();
    }).toList();

    return _invoke('printReceipt', args);
  }

  Future<dynamic> printLabel(Map<String, dynamic> config, List<LineText> data) {
    Map<String, Object> args = Map();
    args['config'] = config;
    args['data'] = data.map((m) {
      return m.toJson();
    }).toList();

    return _invoke('printLabel', args);
  }

  Future<dynamic> print(Map<String, dynamic> config, List<LineText> data) => printReceipt(config, data);

  Future<dynamic> printTest() => _invoke('printTest');

  Future<bool> openCashDrawer({int m = 0, int t1 = 25, int t2 = 250}) async {
    try {
      if (Platform.isAndroid) {
        await _invoke('openCashDrawer');
      } else if (Platform.isIOS) {
        await _invoke('openCashDrawer', {
          'm': m,
          't1': t1,
          't2': t2,
        });
      } else {
        return false;
      }
      return true;
    } on BluetoothPrintException {
      rethrow;
    }
  }

  Future<T?> _invoke<T>(String method, [dynamic arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw BluetoothPrintException.fromPlatformException(error);
    }
  }

}
