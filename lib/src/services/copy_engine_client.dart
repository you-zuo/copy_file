import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/copy_database_service.dart';
import '../data/copy_repository.dart';
import 'copy_engine.dart';

class CopyEngineClient {
  CopyEngineClient({required this.databasePath, this.workerCount = 2});

  final String databasePath;
  final int workerCount;

  final ReceivePort _receivePort = ReceivePort();
  final StreamController<int?> _taskChanges =
      StreamController<int?>.broadcast();
  final Map<int, Completer<void>> _pendingRequests = <int, Completer<void>>{};
  final Set<int> _activeTaskIds = <int>{};
  final Completer<void> _ready = Completer<void>();

  StreamSubscription<dynamic>? _receiveSubscription;
  SendPort? _commandPort;
  Isolate? _isolate;
  int _nextRequestId = 1;

  Stream<int?> get taskChanges => _taskChanges.stream;
  bool get hasActiveTasks => _activeTaskIds.isNotEmpty;

  Future<void> initialize() async {
    if (_isolate != null) {
      return _ready.future;
    }

    _receiveSubscription = _receivePort.listen(_handleMessage);
    _isolate =
        await Isolate.spawn<Map<String, Object?>>(_copyEngineIsolateMain, {
          'replyPort': _receivePort.sendPort,
          'databasePath': databasePath,
          'workerCount': workerCount,
        });
    await _ready.future;
  }

  Future<void> startTask(int taskId) async {
    await _ready.future;
    _activeTaskIds.add(taskId);
    _commandPort!.send({'type': 'start', 'taskId': taskId});
  }

  Future<void> pauseTask(int taskId, {bool resumeOnLaunch = false}) async {
    await _ready.future;
    await _sendRequest({
      'type': 'pause',
      'taskId': taskId,
      'resumeOnLaunch': resumeOnLaunch,
    });
  }

  Future<void> pauseAllForShutdown() async {
    await _ready.future;
    await _sendRequest({'type': 'pauseAllForShutdown'});
  }

  Future<void> dispose() async {
    if (_isolate == null) {
      return;
    }

    if (_commandPort != null) {
      try {
        await _sendRequest({'type': 'dispose'});
      } catch (_) {
        // Ignore isolate shutdown races during app disposal.
      }
    }

    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _pendingRequests.clear();
    _activeTaskIds.clear();

    await _receiveSubscription?.cancel();
    _receivePort.close();
    await _taskChanges.close();

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
  }

  Future<void> _sendRequest(Map<String, Object?> message) {
    final requestId = _nextRequestId++;
    final completer = Completer<void>();
    _pendingRequests[requestId] = completer;
    _commandPort!.send({...message, 'requestId': requestId});
    return completer.future;
  }

  void _handleMessage(dynamic rawMessage) {
    if (rawMessage is! Map<Object?, Object?>) {
      return;
    }

    final message = rawMessage.map(
      (key, value) => MapEntry(key.toString(), value),
    );

    switch (message['type']) {
      case 'ready':
        _commandPort = message['sendPort']! as SendPort;
        if (!_ready.isCompleted) {
          _ready.complete();
        }
        break;
      case 'taskChanged':
        _taskChanges.add(message['taskId'] as int?);
        break;
      case 'taskRunning':
        final taskId = message['taskId']! as int;
        final running = message['running']! as bool;
        if (running) {
          _activeTaskIds.add(taskId);
        } else {
          _activeTaskIds.remove(taskId);
        }
        _taskChanges.add(taskId);
        break;
      case 'ack':
        final requestId = message['requestId']! as int;
        _pendingRequests.remove(requestId)?.complete();
        break;
      case 'error':
        final requestId = message['requestId'] as int?;
        final error = message['error']?.toString() ?? '后台复制线程发生未知错误';
        if (requestId != null) {
          _pendingRequests.remove(requestId)?.completeError(error);
        } else {
          debugPrint(error);
        }
        break;
    }
  }
}

Future<void> _copyEngineIsolateMain(Map<String, Object?> args) async {
  final replyPort = args['replyPort']! as SendPort;
  final databasePath = args['databasePath']! as String;
  final workerCount = args['workerCount']! as int;

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final receivePort = ReceivePort();
  final repository = CopyRepository(
    CopyDatabaseService(databasePath: databasePath),
  );
  await repository.initialize();
  final engine = CopyEngine(repository: repository, workerCount: workerCount);
  final runningTasks = <int>{};

  void notifyRunning(int taskId, bool running) {
    if (running) {
      runningTasks.add(taskId);
    } else {
      runningTasks.remove(taskId);
    }
    replyPort.send({
      'type': 'taskRunning',
      'taskId': taskId,
      'running': running,
    });
  }

  final subscription = repository.changes.listen((taskId) {
    replyPort.send({'type': 'taskChanged', 'taskId': taskId});
  });

  replyPort.send({'type': 'ready', 'sendPort': receivePort.sendPort});

  await for (final dynamic rawMessage in receivePort) {
    if (rawMessage is! Map<Object?, Object?>) {
      continue;
    }
    final message = rawMessage.map(
      (key, value) => MapEntry(key.toString(), value),
    );

    switch (message['type']) {
      case 'start':
        final taskId = message['taskId']! as int;
        if (!runningTasks.contains(taskId)) {
          notifyRunning(taskId, true);
          unawaited(
            engine
                .startTask(taskId)
                .catchError((Object error, StackTrace stackTrace) {
                  replyPort.send({'type': 'error', 'error': error.toString()});
                })
                .whenComplete(() {
                  notifyRunning(taskId, false);
                }),
          );
        }
        break;
      case 'pause':
        final requestId = message['requestId']! as int;
        final taskId = message['taskId']! as int;
        try {
          await engine.pauseTask(
            taskId,
            resumeOnLaunch: message['resumeOnLaunch']! as bool,
          );
          notifyRunning(taskId, false);
          replyPort.send({'type': 'ack', 'requestId': requestId});
        } catch (error) {
          replyPort.send({
            'type': 'error',
            'requestId': requestId,
            'error': error.toString(),
          });
        }
        break;
      case 'pauseAllForShutdown':
        final requestId = message['requestId']! as int;
        try {
          await engine.pauseAllForShutdown();
          for (final taskId in runningTasks.toList(growable: false)) {
            notifyRunning(taskId, false);
          }
          replyPort.send({'type': 'ack', 'requestId': requestId});
        } catch (error) {
          replyPort.send({
            'type': 'error',
            'requestId': requestId,
            'error': error.toString(),
          });
        }
        break;
      case 'dispose':
        final requestId = message['requestId']! as int;
        try {
          await engine.pauseAllForShutdown();
          await subscription.cancel();
          await repository.dispose();
          replyPort.send({'type': 'ack', 'requestId': requestId});
        } finally {
          receivePort.close();
        }
        break;
    }
  }
}
