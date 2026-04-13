import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class CopyVerificationJob {
  const CopyVerificationJob({
    required this.entryId,
    required this.relativePath,
    required this.size,
    required this.sourceMd5,
  });

  final int entryId;
  final String relativePath;
  final int size;
  final String? sourceMd5;

  Map<String, Object?> toMessage() => <String, Object?>{
    'entryId': entryId,
    'relativePath': relativePath,
    'size': size,
    'sourceMd5': sourceMd5,
  };

  factory CopyVerificationJob.fromMessage(Map<String, Object?> message) {
    return CopyVerificationJob(
      entryId: message['entryId']! as int,
      relativePath: message['relativePath']! as String,
      size: message['size']! as int,
      sourceMd5: message['sourceMd5'] as String?,
    );
  }
}

class CopyVerificationResult {
  const CopyVerificationResult({
    required this.entryId,
    required this.mismatchReason,
  });

  final int entryId;
  final String? mismatchReason;

  factory CopyVerificationResult.fromMessage(Map<String, Object?> message) {
    return CopyVerificationResult(
      entryId: message['entryId']! as int,
      mismatchReason: message['mismatchReason'] as String?,
    );
  }
}

class CopyVerifierClient {
  CopyVerifierClient._(this._receivePort);

  final ReceivePort _receivePort;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<List<CopyVerificationResult>>> _pendingRequests =
      <int, Completer<List<CopyVerificationResult>>>{};

  late final StreamSubscription<dynamic> _subscription;
  late final Isolate _isolate;
  SendPort? _commandPort;
  int _nextRequestId = 1;
  bool _disposed = false;

  static Future<CopyVerifierClient> spawn({required String targetDir}) async {
    final receivePort = ReceivePort();
    final client = CopyVerifierClient._(receivePort);
    client._subscription = receivePort.listen(client._handleMessage);
    client._isolate = await Isolate.spawn<Map<String, Object?>>(
      _copyVerifierIsolateMain,
      <String, Object?>{
        'replyPort': receivePort.sendPort,
        'targetDir': targetDir,
      },
    );
    await client._ready.future;
    return client;
  }

  Future<List<CopyVerificationResult>> verifyBatch(
    List<CopyVerificationJob> jobs,
  ) async {
    if (jobs.isEmpty) {
      return const <CopyVerificationResult>[];
    }
    if (_disposed) {
      throw StateError('CopyVerifierClient has been disposed.');
    }

    await _ready.future;
    final requestId = _nextRequestId++;
    final completer = Completer<List<CopyVerificationResult>>();
    _pendingRequests[requestId] = completer;
    _commandPort!.send(<String, Object?>{
      'type': 'verifyBatch',
      'requestId': requestId,
      'entries': jobs.map((job) => job.toMessage()).toList(growable: false),
    });
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    final error = StateError('CopyVerifierClient has been disposed.');
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingRequests.clear();

    await _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
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
      case 'verified':
        final requestId = message['requestId']! as int;
        final rawResults = message['results']! as List<Object?>;
        final results = rawResults
            .map((rawResult) {
              final result = rawResult! as Map<Object?, Object?>;
              return CopyVerificationResult.fromMessage(
                result.map((key, value) => MapEntry(key.toString(), value)),
              );
            })
            .toList(growable: false);
        _pendingRequests.remove(requestId)?.complete(results);
        break;
      case 'error':
        final requestId = message['requestId']! as int;
        final error = message['error']?.toString() ?? '校验 isolate 发生未知错误';
        _pendingRequests.remove(requestId)?.completeError(error);
        break;
    }
  }
}

Future<void> _copyVerifierIsolateMain(Map<String, Object?> args) async {
  final replyPort = args['replyPort']! as SendPort;
  final targetDir = args['targetDir']! as String;
  final receivePort = ReceivePort();

  replyPort.send(<String, Object?>{
    'type': 'ready',
    'sendPort': receivePort.sendPort,
  });

  await for (final dynamic rawMessage in receivePort) {
    if (rawMessage is! Map<Object?, Object?>) {
      continue;
    }

    final message = rawMessage.map(
      (key, value) => MapEntry(key.toString(), value),
    );

    switch (message['type']) {
      case 'verifyBatch':
        final requestId = message['requestId']! as int;
        try {
          final rawEntries = message['entries']! as List<Object?>;
          final results = <Map<String, Object?>>[];
          for (final rawEntry in rawEntries) {
            final entryMap = rawEntry! as Map<Object?, Object?>;
            final job = CopyVerificationJob.fromMessage(
              entryMap.map((key, value) => MapEntry(key.toString(), value)),
            );
            final mismatchReason = await _validateCompletedTarget(
              targetDir: targetDir,
              job: job,
            );
            results.add(<String, Object?>{
              'entryId': job.entryId,
              'mismatchReason': mismatchReason,
            });
          }

          replyPort.send(<String, Object?>{
            'type': 'verified',
            'requestId': requestId,
            'results': results,
          });
        } catch (error) {
          replyPort.send(<String, Object?>{
            'type': 'error',
            'requestId': requestId,
            'error': error.toString(),
          });
        }
        break;
    }
  }
}

Future<String?> _validateCompletedTarget({
  required String targetDir,
  required CopyVerificationJob job,
}) async {
  if (job.sourceMd5 == null || job.sourceMd5!.isEmpty) {
    return '数据库中缺少 MD5，已重置重新拷贝';
  }

  final targetFile = File(p.join(targetDir, job.relativePath));
  if (!await targetFile.exists()) {
    return '目标文件缺失，已重置重新拷贝';
  }

  final fileLength = await targetFile.length();
  if (fileLength != job.size) {
    return '目标文件大小不一致，已重置重新拷贝';
  }

  final targetMd5 = await _hashFile(targetFile);
  if (targetMd5 != job.sourceMd5) {
    return '目标文件 MD5 不一致，已重置重新拷贝';
  }

  return null;
}

Future<String> _hashFile(File file) async {
  final digest = await md5.bind(file.openRead()).first;
  return digest.toString();
}
