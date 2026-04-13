import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/copy_constants.dart';
import '../data/copy_repository.dart';
import '../data/models.dart';
import 'copy_verifier_isolate.dart';

class CopyEngine {
  CopyEngine({required CopyRepository repository, int workerCount = 2})
    : _repository = repository,
      _workerCount = workerCount < 1 ? 1 : workerCount;

  final CopyRepository _repository;
  final int _workerCount;
  final Map<int, _TaskControl> _controls = <int, _TaskControl>{};

  bool get hasActiveTasks => _controls.isNotEmpty;

  Future<void> startTask(int taskId) async {
    final existing = _controls[taskId];
    if (existing != null) {
      return existing.completer.future;
    }

    final control = _TaskControl();
    _controls[taskId] = control;
    unawaited(_runTask(taskId, control));
    return control.completer.future;
  }

  Future<void> pauseTask(int taskId, {bool resumeOnLaunch = false}) async {
    final control = _controls[taskId];
    if (control == null) {
      await _repository.markTaskPaused(taskId, resumeOnLaunch: resumeOnLaunch);
      return;
    }

    control.pauseRequested = true;
    control.resumeOnLaunch = resumeOnLaunch;
    await control.completer.future;
  }

  Future<void> pauseAllForShutdown() async {
    final activeTaskIds = _controls.keys.toList(growable: false);
    for (final taskId in activeTaskIds) {
      await pauseTask(taskId, resumeOnLaunch: true);
    }
  }

  Future<void> _runTask(int taskId, _TaskControl control) async {
    try {
      final task = await _repository.getTask(taskId);
      if (task == null) {
        return;
      }

      if (await _repository.taskNeedsScan(taskId)) {
        await _scanTask(task, control);
      }

      if (control.pauseRequested) {
        await _repository.markTaskPaused(
          taskId,
          resumeOnLaunch: control.resumeOnLaunch,
        );
        return;
      }

      final verificationFuture =
          _verifyCompletedEntriesInBackground(task, control).catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            control.fatalError ??= error;
            throw error;
          });

      await _repository.prepareTaskForRun(taskId);
      await _runCopyPhase(taskId, control);

      final verificationSummary = await verificationFuture;

      if (control.fatalError != null) {
        throw control.fatalError!;
      }

      if (control.pauseRequested) {
        await _repository.markTaskPaused(
          taskId,
          resumeOnLaunch: control.resumeOnLaunch,
        );
        return;
      }

      if (verificationSummary.resetCount > 0) {
        await _runCopyPhase(taskId, control);

        if (control.fatalError != null) {
          throw control.fatalError!;
        }

        if (control.pauseRequested) {
          await _repository.markTaskPaused(
            taskId,
            resumeOnLaunch: control.resumeOnLaunch,
          );
          return;
        }
      }

      await _repository.finalizeTaskStatus(taskId);
    } catch (error) {
      await _repository.markTaskFailed(taskId, error.toString());
    } finally {
      _controls.remove(taskId);
      control.completer.complete();
    }
  }

  Future<void> _runCopyPhase(int taskId, _TaskControl control) async {
    final workers = List<Future<void>>.generate(
      _workerCount,
      (_) => _runCopyWorker(taskId, control),
    );
    await Future.wait(workers);
  }

  Future<void> _runCopyWorker(int taskId, _TaskControl control) async {
    while (!control.pauseRequested && control.fatalError == null) {
      final currentTask = await _repository.getTask(taskId);
      if (currentTask == null) {
        return;
      }

      final entry = await _repository.claimNextPendingEntry(taskId);
      if (entry == null) {
        return;
      }

      try {
        await _copyEntry(currentTask, entry, control);
      } catch (error) {
        control.fatalError ??= error;
        return;
      }
    }
  }

  Future<_VerificationSummary> _verifyCompletedEntriesInBackground(
    CopyTask task,
    _TaskControl control,
  ) async {
    const verificationBatchSize = 16;
    int? afterEntryId;
    var resetCount = 0;
    final verifier = await CopyVerifierClient.spawn(targetDir: task.targetDir);

    try {
      while (!control.pauseRequested) {
        final entries = await _repository.listCompletedEntriesAfter(
          task.id,
          afterEntryId: afterEntryId,
          limit: verificationBatchSize,
        );
        if (entries.isEmpty) {
          break;
        }

        afterEntryId = entries.last.id;
        final results = await verifier.verifyBatch(
          entries
              .map(
                (entry) => CopyVerificationJob(
                  entryId: entry.id,
                  relativePath: entry.relativePath,
                  size: entry.size,
                  sourceMd5: entry.sourceMd5,
                ),
              )
              .toList(growable: false),
        );

        for (final result in results) {
          if (control.pauseRequested) {
            break;
          }

          if (result.mismatchReason case final mismatchReason?) {
            final entry = entries.firstWhere(
              (candidate) => candidate.id == result.entryId,
            );
            final targetFile = File(p.join(task.targetDir, entry.relativePath));
            if (await targetFile.exists()) {
              await targetFile.delete();
            }
            await _repository.resetCompletedEntryForRecopy(
              taskId: task.id,
              entryId: entry.id,
              error: mismatchReason,
            );
            resetCount += 1;
          }
        }
      }

      await _repository.recalculateTaskMetrics(task.id);
      return _VerificationSummary(resetCount: resetCount);
    } finally {
      await verifier.dispose();
    }
  }

  Future<void> _scanTask(CopyTask task, _TaskControl control) async {
    final sourceDirectory = Directory(task.sourceDir);
    if (!await sourceDirectory.exists()) {
      throw Exception('源目录不存在: ${task.sourceDir}');
    }

    await _repository.prepareTaskForScan(task.id);

    final batch = <ScannedEntryDraft>[];
    await for (final entity in sourceDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (control.pauseRequested) {
        return;
      }
      if (entity is! File) {
        continue;
      }

      final stat = await entity.stat();
      final relativePath = p.relative(entity.path, from: task.sourceDir);
      batch.add(
        ScannedEntryDraft(
          relativePath: relativePath,
          size: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      );

      if (batch.length >= 200) {
        await _repository.insertScannedEntries(task.id, List.of(batch));
        batch.clear();
      }
    }

    if (batch.isNotEmpty) {
      await _repository.insertScannedEntries(task.id, List.of(batch));
    }

    await _repository.finishTaskScan(task.id);
  }

  Future<void> _copyEntry(
    CopyTask task,
    CopyEntry entry,
    _TaskControl control,
  ) async {
    final sourceFile = File(p.join(task.sourceDir, entry.relativePath));
    final targetFile = File(p.join(task.targetDir, entry.relativePath));

    if (!await sourceFile.exists()) {
      await _repository.failEntry(
        taskId: task.id,
        entryId: entry.id,
        error: '源文件不存在: ${entry.relativePath}',
      );
      throw Exception('源文件不存在: ${entry.relativePath}');
    }

    final stat = await sourceFile.stat();
    if (stat.size != entry.size ||
        stat.modified.millisecondsSinceEpoch != entry.modifiedMs) {
      await _repository.failEntry(
        taskId: task.id,
        entryId: entry.id,
        error: '源文件已变化，需重新扫描任务',
      );
      throw Exception('源文件已变化: ${entry.relativePath}');
    }

    await targetFile.parent.create(recursive: true);
    final digestSink = _DigestAccumulatorSink();
    final digestInput = md5.startChunkedConversion(digestSink);
    var digestClosed = false;

    void closeDigest() {
      if (digestClosed) {
        return;
      }
      digestInput.close();
      digestClosed = true;
    }

    final resumeOffset = await _prepareDestination(
      task: task,
      entry: entry,
      sourceFile: sourceFile,
      targetFile: targetFile,
      digestInput: digestInput,
    );

    if (resumeOffset < entry.size) {
      final sourceHandle = await sourceFile.open(mode: FileMode.read);
      final targetHandle = await targetFile.open(
        mode: FileMode.writeOnlyAppend,
      );

      try {
        await sourceHandle.setPosition(resumeOffset);
        var offset = resumeOffset;
        var chunkIndex = offset ~/ copyChunkSize;

        while (offset < entry.size) {
          if (control.pauseRequested || control.fatalError != null) {
            break;
          }

          final size = min(copyChunkSize, entry.size - offset);
          final buffer = await sourceHandle.read(size);
          if (buffer.length != size) {
            throw Exception('读取源文件失败: ${entry.relativePath}');
          }

          digestInput.add(buffer);
          await targetHandle.writeFrom(buffer);
          await targetHandle.flush();

          offset += buffer.length;
          await _repository.commitChunk(
            taskId: task.id,
            entryId: entry.id,
            chunkIndex: chunkIndex,
            chunkSize: buffer.length,
            md5: md5.convert(buffer).toString(),
            newBytesCopied: offset,
          );
          chunkIndex += 1;
        }
      } finally {
        await sourceHandle.close();
        await targetHandle.close();
      }
    }

    if (control.pauseRequested || control.fatalError != null) {
      closeDigest();
      return;
    }

    closeDigest();
    final sourceMd5 = digestSink.value!.toString();

    await _repository.completeEntry(
      taskId: task.id,
      entryId: entry.id,
      sourceMd5: sourceMd5,
    );
  }

  Future<int> _prepareDestination({
    required CopyTask task,
    required CopyEntry entry,
    required File sourceFile,
    required File targetFile,
    required ByteConversionSink digestInput,
  }) async {
    final chunks = await _repository.listChunks(entry.id);
    final chunkMap = <int, CopyChunk>{
      for (final chunk in chunks) chunk.chunkIndex: chunk,
    };

    if (!await targetFile.exists()) {
      if (entry.bytesCopied > 0) {
        await _repository.rewindEntryProgress(
          taskId: task.id,
          entryId: entry.id,
          verifiedBytes: 0,
        );
      }
      return 0;
    }

    final currentLength = await targetFile.length();
    var verifiedOffset = 0;
    final trustedLength = min(currentLength, entry.bytesCopied);
    final fullChunks = trustedLength ~/ copyChunkSize;

    final handle = await targetFile.open(mode: FileMode.append);
    try {
      for (var index = 0; index < fullChunks; index += 1) {
        final chunk = chunkMap[index];
        if (chunk == null) {
          break;
        }

        await handle.setPosition(index * copyChunkSize);
        final bytes = await handle.read(chunk.chunkSize);
        if (bytes.length != chunk.chunkSize) {
          break;
        }

        final digest = md5.convert(bytes).toString();
        if (digest != chunk.md5) {
          break;
        }

        digestInput.add(bytes);
        verifiedOffset += chunk.chunkSize;
      }

      if (currentLength != verifiedOffset ||
          entry.bytesCopied != verifiedOffset) {
        await handle.truncate(verifiedOffset);
        await handle.flush();
        await _repository.rewindEntryProgress(
          taskId: task.id,
          entryId: entry.id,
          verifiedBytes: verifiedOffset,
        );
      }
    } finally {
      await handle.close();
    }

    if (verifiedOffset > await sourceFile.length()) {
      await targetFile.writeAsBytes(const <int>[], mode: FileMode.write);
      await _repository.rewindEntryProgress(
        taskId: task.id,
        entryId: entry.id,
        verifiedBytes: 0,
      );
      return 0;
    }

    return verifiedOffset;
  }
}

class _TaskControl {
  final Completer<void> completer = Completer<void>();
  bool pauseRequested = false;
  bool resumeOnLaunch = false;
  Object? fatalError;
}

class _VerificationSummary {
  const _VerificationSummary({required this.resetCount});

  final int resetCount;
}

class _DigestAccumulatorSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
