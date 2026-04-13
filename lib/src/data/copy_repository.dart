import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/copy_constants.dart';
import 'copy_database_service.dart';
import 'models.dart';

class CopyRepository {
  CopyRepository(this._databaseService);

  final CopyDatabaseService _databaseService;
  final StreamController<int?> _changes = StreamController<int?>.broadcast();

  Stream<int?> get changes => _changes.stream;

  Future<Database> get _db async => _databaseService.open();

  Future<void> initialize() async {
    await _db;
  }

  Future<List<CopyTask>> listTasks() async {
    final db = await _db;
    final rows = await db.query(
      'copy_tasks',
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(CopyTask.fromMap).toList();
  }

  Future<CopyTask?> getTask(int taskId) async {
    final db = await _db;
    final rows = await db.query(
      'copy_tasks',
      where: 'id = ?',
      whereArgs: [taskId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return CopyTask.fromMap(rows.first);
  }

  Future<List<CopyEntry>> listEntries(int taskId, {int limit = 60}) async {
    final db = await _db;
    final rows = await db.query(
      'copy_entries',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: '''
        CASE status
          WHEN 'failed' THEN 0
          WHEN 'copying' THEN 1
          WHEN 'pending' THEN 2
          ELSE 3
        END,
        updated_at DESC,
        id DESC
      ''',
      limit: limit,
    );
    return rows.map(CopyEntry.fromMap).toList();
  }

  Future<List<int>> recoverInterruptedTasks() async {
    final db = await _db;
    final rows = await db.query(
      'copy_tasks',
      columns: ['id'],
      where: "status IN (?, ?) OR resume_on_launch = 1",
      whereArgs: [CopyTaskStatus.running.name, CopyTaskStatus.scanning.name],
    );
    final taskIds = rows.map((row) => row['id']! as int).toList();
    if (taskIds.isEmpty) {
      return const [];
    }

    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'copy_tasks',
        {'status': CopyTaskStatus.paused.name, 'updated_at': now},
        where: "status IN (?, ?) OR resume_on_launch = 1",
        whereArgs: [CopyTaskStatus.running.name, CopyTaskStatus.scanning.name],
      );
      await txn.update(
        'copy_entries',
        {'status': CopyEntryStatus.pending.name, 'updated_at': now},
        where:
            'task_id IN (${List.filled(taskIds.length, '?').join(',')})'
            ' AND status = ?',
        whereArgs: [...taskIds, CopyEntryStatus.copying.name],
      );
    });

    for (final taskId in taskIds) {
      _notify(taskId);
    }
    return taskIds;
  }

  Future<int> createTask({
    required String name,
    required String sourceDir,
    required String targetDir,
    required int workerCount,
    String? sourceBookmark,
    String? targetBookmark,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('copy_tasks', {
      'name': name,
      'source_dir': sourceDir,
      'target_dir': targetDir,
      'worker_count': workerCount,
      'source_bookmark': sourceBookmark,
      'target_bookmark': targetBookmark,
      'status': CopyTaskStatus.queued.name,
      'scan_completed': 0,
      'total_files': 0,
      'completed_files': 0,
      'failed_files': 0,
      'total_bytes': 0,
      'copied_bytes': 0,
      'resume_on_launch': 0,
      'created_at': now,
      'updated_at': now,
    });
    _notify(id);
    return id;
  }

  Future<void> updateTaskBookmarks({
    required int taskId,
    String? sourceBookmark,
    String? targetBookmark,
  }) async {
    final db = await _db;
    await db.update(
      'copy_tasks',
      {
        'source_bookmark': sourceBookmark,
        'target_bookmark': targetBookmark,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
    _notify(taskId);
  }

  Future<void> updateTaskDefinition({
    required int taskId,
    required String name,
    required String sourceDir,
    required String targetDir,
    required int workerCount,
    String? sourceBookmark,
    String? targetBookmark,
    required bool resetProgress,
    CopyTaskStatus? status,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      if (resetProgress) {
        await txn.delete(
          'copy_entries',
          where: 'task_id = ?',
          whereArgs: [taskId],
        );
      }

      final values = <String, Object?>{
        'name': name,
        'source_dir': sourceDir,
        'target_dir': targetDir,
        'worker_count': workerCount,
        'updated_at': now,
      };
      if (sourceBookmark != null) {
        values['source_bookmark'] = sourceBookmark;
      }
      if (targetBookmark != null) {
        values['target_bookmark'] = targetBookmark;
      }
      if (resetProgress) {
        values.addAll(<String, Object?>{
          'status': status!.name,
          'scan_completed': 0,
          'total_files': 0,
          'completed_files': 0,
          'failed_files': 0,
          'total_bytes': 0,
          'copied_bytes': 0,
          'resume_on_launch': 0,
          'last_error': null,
        });
      }

      await txn.update(
        'copy_tasks',
        values,
        where: 'id = ?',
        whereArgs: [taskId],
      );
    });
    _notify(taskId);
  }

  Future<void> updateTaskWorkerCount({
    required int taskId,
    required int workerCount,
  }) async {
    final db = await _db;
    await db.update(
      'copy_tasks',
      {
        'worker_count': workerCount,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
    _notify(taskId);
  }

  Future<void> deleteTask(int taskId) async {
    final db = await _db;
    await db.delete('copy_tasks', where: 'id = ?', whereArgs: [taskId]);
    _notify(taskId);
  }

  Future<void> prepareTaskForScan(int taskId) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.delete(
        'copy_entries',
        where: 'task_id = ?',
        whereArgs: [taskId],
      );
      await txn.update(
        'copy_tasks',
        {
          'status': CopyTaskStatus.scanning.name,
          'scan_completed': 0,
          'total_files': 0,
          'completed_files': 0,
          'failed_files': 0,
          'total_bytes': 0,
          'copied_bytes': 0,
          'last_error': null,
          'resume_on_launch': 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [taskId],
      );
    });
    _notify(taskId);
  }

  Future<void> insertScannedEntries(
    int taskId,
    List<ScannedEntryDraft> entries,
  ) async {
    if (entries.isEmpty) {
      return;
    }

    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    var batchBytes = 0;

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in entries) {
        batchBytes += entry.size;
        batch.insert('copy_entries', {
          'task_id': taskId,
          'relative_path': entry.relativePath,
          'size': entry.size,
          'modified_ms': entry.modifiedMs,
          'status': CopyEntryStatus.pending.name,
          'bytes_copied': 0,
          'updated_at': now,
        });
      }
      batch.rawUpdate(
        '''
        UPDATE copy_tasks
        SET total_files = total_files + ?,
            total_bytes = total_bytes + ?,
            updated_at = ?
        WHERE id = ?
        ''',
        [entries.length, batchBytes, now, taskId],
      );
      await batch.commit(noResult: true);
    });
    _notify(taskId);
  }

  Future<void> finishTaskScan(int taskId) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'copy_tasks',
      {
        'status': CopyTaskStatus.running.name,
        'scan_completed': 1,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
    _notify(taskId);
  }

  Future<void> prepareTaskForRun(int taskId) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'copy_tasks',
        {
          'status': CopyTaskStatus.running.name,
          'resume_on_launch': 0,
          'last_error': null,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [taskId],
      );
      await txn.update(
        'copy_entries',
        {
          'status': CopyEntryStatus.pending.name,
          'error': null,
          'updated_at': now,
        },
        where: 'task_id = ? AND status IN (?, ?)',
        whereArgs: [
          taskId,
          CopyEntryStatus.failed.name,
          CopyEntryStatus.copying.name,
        ],
      );
    });
    await recalculateTaskMetrics(taskId);
  }

  Future<void> markTaskPaused(
    int taskId, {
    required bool resumeOnLaunch,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'copy_tasks',
        {
          'status': CopyTaskStatus.paused.name,
          'resume_on_launch': resumeOnLaunch ? 1 : 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [taskId],
      );
      await txn.update(
        'copy_entries',
        {'status': CopyEntryStatus.pending.name, 'updated_at': now},
        where: 'task_id = ? AND status = ?',
        whereArgs: [taskId, CopyEntryStatus.copying.name],
      );
    });
    _notify(taskId);
  }

  Future<void> markTaskFailed(int taskId, String error) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'copy_tasks',
      {
        'status': CopyTaskStatus.failed.name,
        'last_error': error,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
    await recalculateTaskMetrics(taskId);
  }

  Future<void> finalizeTaskStatus(int taskId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT
        COUNT(*) AS total,
        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS completed_count,
        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS failed_count,
        COALESCE(SUM(CASE WHEN status IN (?, ?) THEN 1 ELSE 0 END), 0) AS pending_count,
        COALESCE(SUM(bytes_copied), 0) AS copied_bytes
      FROM copy_entries
      WHERE task_id = ?
      ''',
      [
        CopyEntryStatus.completed.name,
        CopyEntryStatus.failed.name,
        CopyEntryStatus.pending.name,
        CopyEntryStatus.copying.name,
        taskId,
      ],
    );

    if (rows.isEmpty) {
      return;
    }

    final row = rows.first;
    final total = row['total']! as int;
    final completed = row['completed_count']! as int;
    final failed = row['failed_count']! as int;
    final pending = row['pending_count']! as int;
    final copiedBytes = row['copied_bytes']! as int;
    final now = DateTime.now().millisecondsSinceEpoch;

    final status = failed > 0
        ? CopyTaskStatus.failed
        : (total == 0)
        ? CopyTaskStatus.completed
        : (pending > 0 || completed < total)
        ? CopyTaskStatus.paused
        : CopyTaskStatus.completed;

    await db.update(
      'copy_tasks',
      {
        'status': status.name,
        'completed_files': completed,
        'failed_files': failed,
        'copied_bytes': copiedBytes,
        'resume_on_launch': 0,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
    _notify(taskId);
  }

  Future<bool> taskNeedsScan(int taskId) async {
    final task = await getTask(taskId);
    if (task == null) {
      return false;
    }
    if (!task.scanCompleted) {
      return true;
    }
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM copy_entries WHERE task_id = ?',
      [taskId],
    );
    if (rows.isEmpty) {
      return true;
    }
    final raw = rows.first['total'];
    final count = switch (raw) {
      int value => value,
      num value => value.toInt(),
      _ => 0,
    };
    return count == 0;
  }

  Future<CopyEntry?> claimNextPendingEntry(int taskId) async {
    final db = await _db;
    CopyEntry? claimedEntry;

    await db.transaction((txn) async {
      final rows = await txn.query(
        'copy_entries',
        where: 'task_id = ? AND status = ?',
        whereArgs: [taskId, CopyEntryStatus.pending.name],
        orderBy: 'id ASC',
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final row = Map<String, Object?>.from(rows.first);
      final entryId = row['id']! as int;
      await txn.update(
        'copy_entries',
        {
          'status': CopyEntryStatus.copying.name,
          'error': null,
          'updated_at': now,
        },
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
      );

      row['status'] = CopyEntryStatus.copying.name;
      row['error'] = null;
      row['updated_at'] = now;
      claimedEntry = CopyEntry.fromMap(row);
    });

    if (claimedEntry != null) {
      _notify(taskId);
    }
    return claimedEntry;
  }

  Future<List<CopyEntry>> listCompletedEntriesAfter(
    int taskId, {
    int? afterEntryId,
    int limit = 200,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'copy_entries',
      where: afterEntryId == null
          ? 'task_id = ? AND status = ?'
          : 'task_id = ? AND status = ? AND id > ?',
      whereArgs: afterEntryId == null
          ? [taskId, CopyEntryStatus.completed.name]
          : [taskId, CopyEntryStatus.completed.name, afterEntryId],
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows.map(CopyEntry.fromMap).toList();
  }

  Future<List<CopyChunk>> listChunks(int entryId) async {
    final db = await _db;
    final rows = await db.query(
      'copy_chunks',
      where: 'entry_id = ?',
      whereArgs: [entryId],
      orderBy: 'chunk_index ASC',
    );
    return rows.map(CopyChunk.fromMap).toList();
  }

  Future<void> commitChunk({
    required int taskId,
    required int entryId,
    required int chunkIndex,
    required int chunkSize,
    required String md5,
    required int newBytesCopied,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final entryRows = await txn.query(
        'copy_entries',
        columns: ['bytes_copied'],
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
        limit: 1,
      );
      if (entryRows.isEmpty) {
        return;
      }
      final previousBytes = entryRows.first['bytes_copied']! as int;
      final delta = newBytesCopied - previousBytes;

      await txn.insert('copy_chunks', {
        'entry_id': entryId,
        'chunk_index': chunkIndex,
        'chunk_size': chunkSize,
        'md5': md5,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        'copy_entries',
        {
          'bytes_copied': newBytesCopied,
          'status': CopyEntryStatus.copying.name,
          'updated_at': now,
        },
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
      );
      if (delta != 0) {
        await txn.rawUpdate(
          '''
          UPDATE copy_tasks
          SET copied_bytes = copied_bytes + ?,
              updated_at = ?
          WHERE id = ?
          ''',
          [delta, now, taskId],
        );
      }
    });
    _notify(taskId);
  }

  Future<void> rewindEntryProgress({
    required int taskId,
    required int entryId,
    required int verifiedBytes,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'copy_entries',
        columns: ['bytes_copied'],
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final oldBytes = rows.first['bytes_copied']! as int;
      final delta = verifiedBytes - oldBytes;
      await txn.update(
        'copy_entries',
        {
          'bytes_copied': verifiedBytes,
          'status': CopyEntryStatus.pending.name,
          'source_md5': null,
          'error': null,
          'updated_at': now,
        },
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
      );
      await txn.delete(
        'copy_chunks',
        where: 'entry_id = ? AND chunk_index >= ?',
        whereArgs: [entryId, (verifiedBytes / copyChunkSize).ceil()],
      );
      if (delta != 0) {
        await txn.rawUpdate(
          '''
          UPDATE copy_tasks
          SET copied_bytes = copied_bytes + ?,
              updated_at = ?
          WHERE id = ?
          ''',
          [delta, now, taskId],
        );
      }
    });
    _notify(taskId);
  }

  Future<void> resetCompletedEntryForRecopy({
    required int taskId,
    required int entryId,
    required String error,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'copy_entries',
        columns: ['status', 'bytes_copied'],
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }

      final previousStatus = copyEntryStatusFromDb(
        rows.first['status']! as String,
      );
      final previousBytesCopied = rows.first['bytes_copied']! as int;
      await txn.update(
        'copy_entries',
        {
          'status': CopyEntryStatus.pending.name,
          'bytes_copied': 0,
          'source_md5': null,
          'error': error,
          'updated_at': now,
        },
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
      );
      await txn.delete(
        'copy_chunks',
        where: 'entry_id = ?',
        whereArgs: [entryId],
      );
      final completedDelta = previousStatus == CopyEntryStatus.completed
          ? -1
          : 0;
      if (previousBytesCopied != 0 || completedDelta != 0) {
        await txn.rawUpdate(
          '''
          UPDATE copy_tasks
          SET copied_bytes = MAX(copied_bytes + ?, 0),
              completed_files = MAX(completed_files + ?, 0),
              updated_at = ?
          WHERE id = ?
          ''',
          [-previousBytesCopied, completedDelta, now, taskId],
        );
      } else {
        await txn.update(
          'copy_tasks',
          {'updated_at': now},
          where: 'id = ?',
          whereArgs: [taskId],
        );
      }
    });
    _notify(taskId);
  }

  Future<void> completeEntry({
    required int taskId,
    required int entryId,
    required String sourceMd5,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'copy_entries',
        columns: ['size', 'bytes_copied'],
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final size = rows.first['size']! as int;
      final bytesCopied = rows.first['bytes_copied']! as int;
      final delta = size - bytesCopied;
      await txn.update(
        'copy_entries',
        {
          'status': CopyEntryStatus.completed.name,
          'bytes_copied': size,
          'source_md5': sourceMd5,
          'error': null,
          'updated_at': now,
        },
        where: 'id = ? AND task_id = ?',
        whereArgs: [entryId, taskId],
      );
      if (delta != 0) {
        await txn.rawUpdate(
          '''
          UPDATE copy_tasks
          SET copied_bytes = copied_bytes + ?,
              updated_at = ?
          WHERE id = ?
          ''',
          [delta, now, taskId],
        );
      } else {
        await txn.update(
          'copy_tasks',
          {'updated_at': now},
          where: 'id = ?',
          whereArgs: [taskId],
        );
      }
    });
    await recalculateTaskMetrics(taskId);
  }

  Future<void> failEntry({
    required int taskId,
    required int entryId,
    required String error,
  }) async {
    final db = await _db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'copy_entries',
      {
        'status': CopyEntryStatus.failed.name,
        'error': error,
        'updated_at': now,
      },
      where: 'id = ? AND task_id = ?',
      whereArgs: [entryId, taskId],
    );
    await recalculateTaskMetrics(taskId);
  }

  Future<void> recalculateTaskMetrics(int taskId) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(bytes_copied), 0) AS copied_bytes,
        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS completed_count,
        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS failed_count
      FROM copy_entries
      WHERE task_id = ?
      ''',
      [CopyEntryStatus.completed.name, CopyEntryStatus.failed.name, taskId],
    );
    if (rows.isEmpty) {
      return;
    }
    final row = rows.first;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'copy_tasks',
      {
        'copied_bytes': row['copied_bytes']! as int,
        'completed_files': row['completed_count']! as int,
        'failed_files': row['failed_count']! as int,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [taskId],
    );
    _notify(taskId);
  }

  Future<void> dispose() async {
    await _changes.close();
    await _databaseService.close();
  }

  void _notify(int? taskId) {
    if (!_changes.isClosed) {
      _changes.add(taskId);
    }
  }
}
