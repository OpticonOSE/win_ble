import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// A class that connects to the BLE server and sends/receives messages
/// Make sure to call [initialize] before using [invokeMethod]
class WinConnector {
  WinConnector({
    ProcessStarter? processStarter,
    this.defaultRequestTimeout = const Duration(seconds: 60),
  }) : _processStarter = processStarter ?? _startProcess;

  static Future<Process> _startProcess(
    String executable,
    List<String> arguments,
  ) => Process.start(executable, arguments);

  final ProcessStarter _processStarter;
  final Duration defaultRequestTimeout;
  int _requestId = 0;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  StreamSubscription? _exitSubscription;
  Process? _bleServer;
  final Map<int, Completer<dynamic>> _pendingRequests = {};
  final BytesBuilder _stdoutBuffer = BytesBuilder(copy: false);
  Future<void> _pendingWrite = Future.value();
  bool _isClosing = false;

  Future<void> initialize({
    Function(dynamic)? onData,
    required String serverPath,
  }) async {
    _isClosing = false;
    File bleFile = File(serverPath);
    final bleServer = await _processStarter(bleFile.path, []);
    _bleServer = bleServer;
    _stdoutSubscription = bleServer.stdout.listen((event) {
      try {
        final listData = _dataParser(event);
        for (var data in listData) {
          _handleResponse(data);
          onData?.call(data);
        }
      } catch (error, stackTrace) {
        _terminateHelper(
          StateError('BLE helper returned invalid data: $error'),
          stackTrace,
        );
      }
    });

    _stderrSubscription = bleServer.stderr.listen((event) {
      stderr.write(String.fromCharCodes(event));
    });

    _exitSubscription = bleServer.exitCode.asStream().listen((exitCode) {
      if (!identical(_bleServer, bleServer)) return;
      _bleServer = null;
      _isClosing = true;
      _failPendingRequests(StateError('BLE helper exited with code $exitCode'));
    });
  }

  Future invokeMethod(
    String method, {
    Map<String, dynamic>? args,
    bool waitForResult = true,
    Duration? timeout,
  }) async {
    final result = <String, dynamic>{...?args};
    // If we don't need to wait for the result, just send the message and return
    if (!waitForResult) {
      await _sendMessage(method: method, args: result);
      return;
    }
    // If we need to wait for the result, we need to generate a unique ID
    int uniqID = _requestId++;
    result["_id"] = uniqID;
    final completer = Completer<dynamic>();
    _pendingRequests[uniqID] = completer;

    try {
      await _sendMessage(method: method, args: result);
      return await completer.future.timeout(
        timeout ?? defaultRequestTimeout,
        onTimeout: () {
          final error = TimeoutException(
            'BLE helper did not complete $method',
            timeout ?? defaultRequestTimeout,
          );
          _terminateHelper(error);
          throw error;
        },
      );
    } catch (_) {
      _pendingRequests.remove(uniqID);
      rethrow;
    }
  }

  void dispose() {
    _isClosing = true;
    _failPendingRequests(StateError('BLE helper was disposed'));
    _pendingWrite = Future.value();
    _exitSubscription?.cancel();
    _stderrSubscription?.cancel();
    _stdoutSubscription?.cancel();
    _bleServer?.kill();
    _bleServer = null;
    _stdoutBuffer.clear();
  }

  void _handleResponse(response) {
    try {
      if (response["_type"] == "response") {
        final id = response["_id"];
        if (id is! int) return;
        final completer = _pendingRequests.remove(id);
        if (completer == null || completer.isCompleted) return;
        final error = response["error"];
        if (error != null) {
          completer.completeError(error);
        } else {
          completer.complete(response["result"]);
        }
      }
    } catch (_) {}
  }

  void _terminateHelper(Object error, [StackTrace? stackTrace]) {
    if (_isClosing && _bleServer == null) return;
    _isClosing = true;
    final bleServer = _bleServer;
    _bleServer = null;
    _failPendingRequests(error, stackTrace);
    bleServer?.kill();
  }

  void _failPendingRequests(Object error, [StackTrace? stackTrace]) {
    final pending = _pendingRequests.values.toList(growable: false);
    _pendingRequests.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  Future<void> _sendMessage({
    required String method,
    Map<String, dynamic>? args,
  }) async {
    if (_isClosing) {
      throw StateError('BLE helper is not available');
    }

    final bleServer = _bleServer;
    if (bleServer == null) {
      throw StateError('BLE helper is not initialized');
    }

    Map<String, dynamic> result = {"cmd": method};
    if (args != null) result.addAll(args);
    final data = json.encode(result);
    final dataBufInt = utf8.encode(data);
    final lenBufInt = _createUInt32LE(dataBufInt.length);

    Future<void> writeOperation() async {
      if (_isClosing || !identical(_bleServer, bleServer)) return;

      try {
        await bleServer.stdin.addStream(
          Stream<List<int>>.fromIterable([lenBufInt, dataBufInt]),
        );
      } on SocketException catch (e) {
        final isPipeClosing = e.osError?.errorCode == 232;
        if (_isClosing && isPipeClosing) {
          return;
        }
        rethrow;
      }
    }

    final queuedWrite = _pendingWrite.then((_) => writeOperation());
    _pendingWrite = queuedWrite.catchError((_) {});
    await queuedWrite;
  }

  List<int> _createUInt32LE(int value) {
    final result = Uint8List(4);
    for (int i = 0; i < 4; i++, value >>= 8) {
      result[i] = value & 0xFF;
    }
    return result;
  }

  List<dynamic> _dataParser(List<int> event) {
    _stdoutBuffer.add(event);

    final buffered = _stdoutBuffer.takeBytes();
    final input = Uint8List.fromList(buffered);
    final output = <dynamic>[];
    var cursor = 0;

    while (cursor + 4 <= input.length) {
      final length = _fromBytesToInt32(
        input[cursor + 0],
        input[cursor + 1],
        input[cursor + 2],
        input[cursor + 3],
      );

      if (length < 0) {
        throw const FormatException('Negative BLE helper payload length');
      }

      final frameStart = cursor + 4;
      final frameEnd = frameStart + length;
      if (frameEnd > input.length) {
        break;
      }

      final payloadBytes = input.sublist(frameStart, frameEnd);
      final payload = utf8.decode(payloadBytes);
      output.add(json.decode(payload));
      cursor = frameEnd;
    }

    if (cursor < input.length) {
      _stdoutBuffer.add(input.sublist(cursor));
    }

    return output;
  }

  int _fromBytesToInt32(int b3, int b2, int b1, int b0) {
    final int8List = Int8List(4)
      ..[3] = b3
      ..[2] = b2
      ..[1] = b1
      ..[0] = b0;
    return int8List.buffer.asByteData().getInt32(0);
  }
}
