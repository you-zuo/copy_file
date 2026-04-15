import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:copy_file/src/core/copy_constants.dart';
import 'package:copy_file/src/data/copy_database_service.dart';
import 'package:copy_file/src/data/copy_repository.dart';
import 'package:copy_file/src/data/models.dart';
import 'package:copy_file/src/services/copy_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('CopyEngine copies files larger than one chunk', () async {
    final harness = await _CopyEngineHarness.create();
    try {
      final sourceFile = File(p.join(harness.sourceDir.path, 'video.bin'));
      await _writePatternFile(sourceFile, copyChunkSize + 1024 * 1024);

      final taskId = await harness.repository.createTask(
        name: 'large copy',
        sourceDir: harness.sourceDir.path,
        targetDir: harness.targetDir.path,
        workerCount: 1,
      );

      await harness.engine.startTask(
        taskId,
        verifyCompletedEntriesOnStart: false,
      );

      final task = await harness.repository.getTask(taskId);
      final entry = (await harness.repository.listEntries(taskId)).single;
      final targetFile = File(p.join(harness.targetDir.path, 'video.bin'));

      expect(task?.status, CopyTaskStatus.completed);
      expect(entry.status, CopyEntryStatus.completed);
      expect(await targetFile.length(), await sourceFile.length());
      expect(await _hashFile(targetFile), await _hashFile(sourceFile));
    } finally {
      await harness.dispose();
    }
  });

  test(
    'CopyEngine copies small files without persisting chunk metadata',
    () async {
      final harness = await _CopyEngineHarness.create();
      try {
        final sourceFile = File(p.join(harness.sourceDir.path, 'clip.bin'));
        await _writePatternFile(sourceFile, singlePassCopyThreshold);

        final taskId = await harness.repository.createTask(
          name: 'small copy',
          sourceDir: harness.sourceDir.path,
          targetDir: harness.targetDir.path,
          workerCount: 1,
        );

        await harness.engine.startTask(
          taskId,
          verifyCompletedEntriesOnStart: false,
        );

        final entry = (await harness.repository.listEntries(taskId)).single;
        final targetFile = File(p.join(harness.targetDir.path, 'clip.bin'));

        expect(entry.status, CopyEntryStatus.completed);
        expect(await harness.repository.listChunks(entry.id), isEmpty);
        expect(await targetFile.length(), await sourceFile.length());
        expect(await _hashFile(targetFile), await _hashFile(sourceFile));
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'CopyEngine recopies small files from scratch when stale progress exists',
    () async {
      final harness = await _CopyEngineHarness.create();
      try {
        final relativePath = 'clip.bin';
        final sourceFile = File(p.join(harness.sourceDir.path, relativePath));
        await _writePatternFile(sourceFile, singlePassCopyThreshold ~/ 2);
        final stat = await sourceFile.stat();

        final taskId = await harness.repository.createTask(
          name: 'small recopy',
          sourceDir: harness.sourceDir.path,
          targetDir: harness.targetDir.path,
          workerCount: 1,
        );

        await harness.repository.prepareTaskForScan(taskId);
        await harness.repository
            .insertScannedEntries(taskId, <ScannedEntryDraft>[
              ScannedEntryDraft(
                relativePath: relativePath,
                size: stat.size,
                modifiedMs: stat.modified.millisecondsSinceEpoch,
              ),
            ]);
        await harness.repository.finishTaskScan(taskId);

        final entry = (await harness.repository.listEntries(taskId)).single;
        final targetFile = File(p.join(harness.targetDir.path, relativePath));
        await targetFile.parent.create(recursive: true);

        final partialLength = stat.size ~/ 2;
        final partialBytes = await _readRange(sourceFile, partialLength);
        await targetFile.writeAsBytes(partialBytes, flush: true);
        await harness.repository.commitChunk(
          taskId: taskId,
          entryId: entry.id,
          chunkIndex: 0,
          chunkSize: partialBytes.length,
          md5: md5.convert(partialBytes).toString(),
          newBytesCopied: partialBytes.length,
        );

        await harness.engine.startTask(
          taskId,
          verifyCompletedEntriesOnStart: false,
        );

        final resumedEntry = (await harness.repository.listEntries(
          taskId,
        )).single;

        expect(resumedEntry.status, CopyEntryStatus.completed);
        expect(await harness.repository.listChunks(entry.id), isEmpty);
        expect(await targetFile.length(), await sourceFile.length());
        expect(await _hashFile(targetFile), await _hashFile(sourceFile));
      } finally {
        await harness.dispose();
      }
    },
  );

  test('CopyEngine resumes large files from verified chunk progress', () async {
    final harness = await _CopyEngineHarness.create();
    try {
      final relativePath = 'video.bin';
      final sourceFile = File(p.join(harness.sourceDir.path, relativePath));
      await _writePatternFile(sourceFile, copyChunkSize * 2 + 12345);
      final stat = await sourceFile.stat();

      final taskId = await harness.repository.createTask(
        name: 'resume copy',
        sourceDir: harness.sourceDir.path,
        targetDir: harness.targetDir.path,
        workerCount: 1,
      );

      await harness.repository.prepareTaskForScan(taskId);
      await harness.repository.insertScannedEntries(taskId, <ScannedEntryDraft>[
        ScannedEntryDraft(
          relativePath: relativePath,
          size: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      ]);
      await harness.repository.finishTaskScan(taskId);

      final entry = (await harness.repository.listEntries(taskId)).single;
      final targetFile = File(p.join(harness.targetDir.path, relativePath));
      await targetFile.parent.create(recursive: true);

      final firstChunk = await _readRange(sourceFile, copyChunkSize);
      await targetFile.writeAsBytes(firstChunk, flush: true);
      await harness.repository.commitChunk(
        taskId: taskId,
        entryId: entry.id,
        chunkIndex: 0,
        chunkSize: firstChunk.length,
        md5: md5.convert(firstChunk).toString(),
        newBytesCopied: firstChunk.length,
      );

      await harness.engine.startTask(
        taskId,
        verifyCompletedEntriesOnStart: false,
      );

      final task = await harness.repository.getTask(taskId);
      final resumedEntry = (await harness.repository.listEntries(
        taskId,
      )).single;

      expect(task?.status, CopyTaskStatus.completed);
      expect(resumedEntry.status, CopyEntryStatus.completed);
      expect(await targetFile.length(), await sourceFile.length());
      expect(await _hashFile(targetFile), await _hashFile(sourceFile));
    } finally {
      await harness.dispose();
    }
  });

  test(
    'CopyEngine does not auto-verify completed entries when restarting a paused task',
    () async {
      final harness = await _CopyEngineHarness.create();
      try {
        final relativePath = 'done.bin';
        final sourceFile = File(p.join(harness.sourceDir.path, relativePath));
        await _writePatternFile(sourceFile, copyChunkSize ~/ 2);
        final sourceHash = await _hashFile(sourceFile);
        final stat = await sourceFile.stat();

        final taskId = await harness.repository.createTask(
          name: 'skip completed verification',
          sourceDir: harness.sourceDir.path,
          targetDir: harness.targetDir.path,
          workerCount: 1,
        );

        await harness.repository.prepareTaskForScan(taskId);
        await harness.repository
            .insertScannedEntries(taskId, <ScannedEntryDraft>[
              ScannedEntryDraft(
                relativePath: relativePath,
                size: stat.size,
                modifiedMs: stat.modified.millisecondsSinceEpoch,
              ),
            ]);
        await harness.repository.finishTaskScan(taskId);

        final entry = (await harness.repository.listEntries(taskId)).single;
        final targetFile = File(p.join(harness.targetDir.path, relativePath));
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(
          Uint8List.fromList(List<int>.filled(stat.size, 7, growable: false)),
          flush: true,
        );
        final corruptedHash = await _hashFile(targetFile);

        await harness.repository.completeEntry(
          taskId: taskId,
          entryId: entry.id,
          sourceMd5: sourceHash,
        );
        await harness.repository.markTaskPaused(taskId, resumeOnLaunch: false);

        await harness.engine.startTask(
          taskId,
          verifyCompletedEntriesOnStart: false,
        );

        final task = await harness.repository.getTask(taskId);
        final resumedEntry = (await harness.repository.listEntries(
          taskId,
        )).single;

        expect(task?.status, CopyTaskStatus.completed);
        expect(resumedEntry.status, CopyEntryStatus.completed);
        expect(await _hashFile(targetFile), corruptedHash);
        expect(await _hashFile(targetFile), isNot(sourceHash));
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'CopyEngine can verify completed entries on restart when the switch is enabled',
    () async {
      final harness = await _CopyEngineHarness.create();
      try {
        final relativePath = 'done.bin';
        final sourceFile = File(p.join(harness.sourceDir.path, relativePath));
        await _writePatternFile(sourceFile, copyChunkSize ~/ 2);
        final sourceHash = await _hashFile(sourceFile);
        final stat = await sourceFile.stat();

        final taskId = await harness.repository.createTask(
          name: 'verify completed verification',
          sourceDir: harness.sourceDir.path,
          targetDir: harness.targetDir.path,
          workerCount: 1,
        );

        await harness.repository.prepareTaskForScan(taskId);
        await harness.repository
            .insertScannedEntries(taskId, <ScannedEntryDraft>[
              ScannedEntryDraft(
                relativePath: relativePath,
                size: stat.size,
                modifiedMs: stat.modified.millisecondsSinceEpoch,
              ),
            ]);
        await harness.repository.finishTaskScan(taskId);

        final entry = (await harness.repository.listEntries(taskId)).single;
        final targetFile = File(p.join(harness.targetDir.path, relativePath));
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(
          Uint8List.fromList(List<int>.filled(stat.size, 7, growable: false)),
          flush: true,
        );

        await harness.repository.completeEntry(
          taskId: taskId,
          entryId: entry.id,
          sourceMd5: sourceHash,
        );
        await harness.repository.markTaskPaused(taskId, resumeOnLaunch: false);

        await harness.engine.startTask(
          taskId,
          verifyCompletedEntriesOnStart: true,
        );

        final task = await harness.repository.getTask(taskId);
        final resumedEntry = (await harness.repository.listEntries(
          taskId,
        )).single;

        expect(task?.status, CopyTaskStatus.completed);
        expect(resumedEntry.status, CopyEntryStatus.completed);
        expect(await _hashFile(targetFile), sourceHash);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'repository persists verify switch and only allows updates while paused',
    () async {
      final harness = await _CopyEngineHarness.create();
      try {
        final taskId = await harness.repository.createTask(
          name: 'verify switch',
          sourceDir: harness.sourceDir.path,
          targetDir: harness.targetDir.path,
          workerCount: 1,
        );

        expect(
          (await harness.repository.getTask(taskId))?.verifyCompletedOnResume,
          isFalse,
        );

        await expectLater(
          () => harness.repository.updateTaskVerifyCompletedOnResume(
            taskId: taskId,
            enabled: true,
          ),
          throwsException,
        );

        await harness.repository.markTaskPaused(taskId, resumeOnLaunch: false);
        await harness.repository.updateTaskVerifyCompletedOnResume(
          taskId: taskId,
          enabled: true,
        );

        expect(
          (await harness.repository.getTask(taskId))?.verifyCompletedOnResume,
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'repository updates task metrics incrementally for complete and fail',
    () async {
      final harness = await _CopyEngineHarness.create();
      try {
        final taskId = await harness.repository.createTask(
          name: 'incremental metrics',
          sourceDir: harness.sourceDir.path,
          targetDir: harness.targetDir.path,
          workerCount: 1,
        );

        await harness.repository.prepareTaskForScan(taskId);
        await harness.repository
            .insertScannedEntries(taskId, <ScannedEntryDraft>[
              const ScannedEntryDraft(
                relativePath: 'a.bin',
                size: 3,
                modifiedMs: 1,
              ),
              const ScannedEntryDraft(
                relativePath: 'b.bin',
                size: 5,
                modifiedMs: 1,
              ),
            ]);
        await harness.repository.finishTaskScan(taskId);

        final entries = await harness.repository.listEntries(taskId);
        final firstEntry = entries.firstWhere(
          (entry) => entry.relativePath == 'a.bin',
        );
        final secondEntry = entries.firstWhere(
          (entry) => entry.relativePath == 'b.bin',
        );

        await harness.repository.commitChunk(
          taskId: taskId,
          entryId: firstEntry.id,
          chunkIndex: 0,
          chunkSize: 2,
          md5: md5.convert(const <int>[1, 2]).toString(),
          newBytesCopied: 2,
        );

        var task = await harness.repository.getTask(taskId);
        expect(task?.copiedBytes, 2);
        expect(task?.completedFiles, 0);
        expect(task?.failedFiles, 0);

        await harness.repository.completeEntry(
          taskId: taskId,
          entryId: firstEntry.id,
          sourceMd5: 'done',
        );

        task = await harness.repository.getTask(taskId);
        expect(task?.copiedBytes, 3);
        expect(task?.completedFiles, 1);
        expect(task?.failedFiles, 0);

        await harness.repository.failEntry(
          taskId: taskId,
          entryId: secondEntry.id,
          error: 'boom',
        );

        task = await harness.repository.getTask(taskId);
        expect(task?.copiedBytes, 3);
        expect(task?.completedFiles, 1);
        expect(task?.failedFiles, 1);
      } finally {
        await harness.dispose();
      }
    },
  );
}

class _CopyEngineHarness {
  _CopyEngineHarness({
    required this.rootDir,
    required this.sourceDir,
    required this.targetDir,
    required this.repository,
    required this.engine,
  });

  final Directory rootDir;
  final Directory sourceDir;
  final Directory targetDir;
  final CopyRepository repository;
  final CopyEngine engine;

  static Future<_CopyEngineHarness> create() async {
    final rootDir = await Directory.systemTemp.createTemp('copy_engine_test_');
    final sourceDir = Directory(p.join(rootDir.path, 'source'));
    final targetDir = Directory(p.join(rootDir.path, 'target'));
    await sourceDir.create(recursive: true);
    await targetDir.create(recursive: true);

    final databasePath = p.join(rootDir.path, 'copy_file.db');
    final repository = CopyRepository(
      CopyDatabaseService(databasePath: databasePath),
    );
    await repository.initialize();

    return _CopyEngineHarness(
      rootDir: rootDir,
      sourceDir: sourceDir,
      targetDir: targetDir,
      repository: repository,
      engine: CopyEngine(repository: repository),
    );
  }

  Future<void> dispose() async {
    await repository.dispose();
    if (await rootDir.exists()) {
      await rootDir.delete(recursive: true);
    }
  }
}

Future<void> _writePatternFile(File file, int size) async {
  await file.parent.create(recursive: true);
  final sink = file.openWrite();
  const blockSize = 1024 * 1024;
  var written = 0;
  while (written < size) {
    final nextBlockSize = min(blockSize, size - written);
    final block = Uint8List.fromList(
      List<int>.generate(
        nextBlockSize,
        (index) => (written + index) % 251,
        growable: false,
      ),
    );
    sink.add(block);
    written += nextBlockSize;
  }
  await sink.close();
}

Future<Uint8List> _readRange(File file, int length) async {
  final handle = await file.open(mode: FileMode.read);
  try {
    final builder = BytesBuilder(copy: false);
    var remaining = length;
    while (remaining > 0) {
      final chunk = await handle.read(remaining);
      if (chunk.isEmpty) {
        break;
      }
      builder.add(chunk);
      remaining -= chunk.length;
    }
    return builder.takeBytes();
  } finally {
    await handle.close();
  }
}

Future<String> _hashFile(File file) async {
  final digest = await md5.bind(file.openRead()).first;
  return digest.toString();
}
