import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

import 'bluetooth_print_model.dart';

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

  static BluetoothPrint _instance = new BluetoothPrint._();

  static BluetoothPrint get instance => _instance;

  Future<bool> get isAvailable async => await _channel.invokeMethod('isAvailable').then<bool>((d) => d);

  Future<bool> get isOn async => await _channel.invokeMethod('isOn').then<bool>((d) => d);

  Future<bool?> get isConnected async => await _channel.invokeMethod('isConnected');

  BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);

  Stream<bool> get isScanning => _isScanning.stream;

  BehaviorSubject<List<BluetoothDevice>> _scanResults = BehaviorSubject.seeded([]);

  Stream<List<BluetoothDevice>> get scanResults => _scanResults.stream;

  PublishSubject _stopScanPill = new PublishSubject();
  Stream<int>? _stateStream;

  /// Gets the current state of the Bluetooth module
  Stream<int> _buildStateStream() async* {
    yield await _channel.invokeMethod('state').then((s) => s);

    yield* _stateChannel.receiveBroadcastStream().map((s) => s);
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
      await _channel.invokeMethod('startScan');
    } catch (e) {
      print('Error starting scan.');
      _stopScanPill.add(null);
      _isScanning.add(false);
      throw e;
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
    await _channel.invokeMethod('stopScan');
    _stopScanPill.add(null);
    _isScanning.add(false);
  }

  Future<dynamic> connect(BluetoothDevice device) => _channel.invokeMethod('connect', device.toJson());

  Future<dynamic> disconnect() => _channel.invokeMethod('disconnect');

  Future<dynamic> destroy() => _channel.invokeMethod('destroy');

  Future<List<Map<String, dynamic>>> getDebugLogs() async {
    final logs = await _channel.invokeMethod('getDebugLogs');
    if (logs is! List) return <Map<String, dynamic>>[];
    return logs.map((entry) => Map<String, dynamic>.from(entry as Map)).toList();
  }

  Future<dynamic> clearDebugLogs() => _channel.invokeMethod('clearDebugLogs');

  Future<dynamic> printReceipt(Map<String, dynamic> config, List<LineText> data) {
    Map<String, Object> args = Map();
    args['config'] = config;
    args['data'] = data.map((m) {
      return m.toJson();
    }).toList();

    _channel.invokeMethod('printReceipt', args);
    return Future.value(true);
  }

  Future<dynamic> printLabel(Map<String, dynamic> config, List<LineText> data) {
    Map<String, Object> args = Map();
    args['config'] = config;
    args['data'] = data.map((m) {
      return m.toJson();
    }).toList();

    _channel.invokeMethod('printLabel', args);
    return Future.value(true);
  }

  Future<dynamic> printTest() => _channel.invokeMethod('printTest');

  Future<bool> openCashDrawer({int m = 0, int t1 = 25, int t2 = 250}) async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('openCashDrawer');
        print('Open cash drawer command sent successfully on Android.');
      } else if (Platform.isIOS) {
        // Call the openCashDrawer method on iOS
        await _channel.invokeMethod('openCashDrawer', {
          'm': m, // Cash drawer pin number (commonly 0 or 1)
          't1': t1, // High-level pulse time in milliseconds
          't2': t2, // Low-level pulse time in milliseconds
        });
        print('Open cash drawer command sent successfully on iOS.');
      } else {
        print('Unsupported platform.');
        return false;
      }
      return true;
    } on PlatformException catch (e) {
      print("Failed to open cash drawer: '${e.message}'.");
      return false;
    }
  }
}
