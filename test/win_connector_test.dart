import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:win_ble/src/utils/win_connector.dart';

void main() {
  test('completes a request from its matching helper response', () async {
    final process = _FakeProcess();
    final request = _captureNextRequest(process);
    final connector = WinConnector(processStarter: (_, __) async => process);
    await connector.initialize(serverPath: 'BLEServer.exe');

    final resultFuture = connector.invokeMethod('ping');
    final command = await request;
    process.sendMessage({
      '_type': 'response',
      '_id': command['_id'],
      'result': 'pong',
      'error': null,
    });

    expect(await resultFuture, 'pong');
    connector.dispose();
  });

  test('fails pending requests when the helper exits', () async {
    final process = _FakeProcess();
    final request = _captureNextRequest(process);
    final connector = WinConnector(processStarter: (_, __) async => process);
    await connector.initialize(serverPath: 'BLEServer.exe');

    final resultFuture = connector.invokeMethod('radioState');
    await request;
    process.exit(17);

    await expectLater(
      resultFuture,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('exited with code 17'),
        ),
      ),
    );
    connector.dispose();
  });

  test('times out and terminates an unresponsive helper', () async {
    final process = _FakeProcess();
    final request = _captureNextRequest(process);
    final connector = WinConnector(
      processStarter: (_, __) async => process,
      defaultRequestTimeout: const Duration(milliseconds: 20),
    );
    await connector.initialize(serverPath: 'BLEServer.exe');

    final resultFuture = connector.invokeMethod('services');
    await request;

    await expectLater(resultFuture, throwsA(isA<TimeoutException>()));
    expect(process.wasKilled, isTrue);
    connector.dispose();
  });

  test('fails pending requests when disposed', () async {
    final process = _FakeProcess();
    final request = _captureNextRequest(process);
    final connector = WinConnector(processStarter: (_, __) async => process);
    await connector.initialize(serverPath: 'BLEServer.exe');

    final resultFuture = connector.invokeMethod('read');
    await request;
    connector.dispose();

    await expectLater(
      resultFuture,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('disposed'),
        ),
      ),
    );
  });
}

Future<Map<String, dynamic>> _captureNextRequest(_FakeProcess process) {
  final completer = Completer<Map<String, dynamic>>();
  final buffer = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> subscription;
  subscription = process.input.listen((chunk) {
    buffer.add(chunk);
    final bytes = buffer.toBytes();
    if (bytes.length < 4) return;
    final length = ByteData.sublistView(bytes).getUint32(0, Endian.little);
    if (bytes.length < length + 4) return;
    final decoded = json.decode(utf8.decode(bytes.sublist(4, length + 4)));
    subscription.cancel();
    completer.complete(Map<String, dynamic>.from(decoded as Map));
  });
  return completer.future;
}

List<int> _encodeMessage(Map<String, dynamic> message) {
  final payload = utf8.encode(json.encode(message));
  final frame = BytesBuilder(copy: false)
    ..add(
      (ByteData(
        4,
      )..setUint32(0, payload.length, Endian.little)).buffer.asUint8List(),
    )
    ..add(payload);
  return frame.takeBytes();
}

final class _FakeProcess implements Process {
  final _inputController = StreamController<List<int>>();
  final _stdoutController = StreamController<List<int>>();
  final _stderrController = StreamController<List<int>>();
  final _exitCompleter = Completer<int>();
  late final IOSink _stdin = IOSink(_inputController.sink);

  bool wasKilled = false;

  Stream<List<int>> get input => _inputController.stream;

  void sendMessage(Map<String, dynamic> message) {
    _stdoutController.add(_encodeMessage(message));
  }

  void exit(int code) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(code);
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  int get pid => 1;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    wasKilled = true;
    exit(0);
    return true;
  }
}
