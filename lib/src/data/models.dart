enum CopyTaskStatus { queued, scanning, running, paused, completed, failed }

enum CopyEntryStatus { pending, copying, completed, failed }

CopyTaskStatus copyTaskStatusFromDb(String raw) {
  return CopyTaskStatus.values.firstWhere(
    (value) => value.name == raw,
    orElse: () => CopyTaskStatus.paused,
  );
}

CopyEntryStatus copyEntryStatusFromDb(String raw) {
  return CopyEntryStatus.values.firstWhere(
    (value) => value.name == raw,
    orElse: () => CopyEntryStatus.pending,
  );
}

class CopyTask {
  const CopyTask({
    required this.id,
    required this.name,
    required this.sourceDir,
    required this.targetDir,
    required this.workerCount,
    required this.sourceBookmark,
    required this.targetBookmark,
    required this.status,
    required this.scanCompleted,
    required this.totalFiles,
    required this.completedFiles,
    required this.failedFiles,
    required this.totalBytes,
    required this.copiedBytes,
    required this.resumeOnLaunch,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
  });

  final int id;
  final String name;
  final String sourceDir;
  final String targetDir;
  final int workerCount;
  final String? sourceBookmark;
  final String? targetBookmark;
  final CopyTaskStatus status;
  final bool scanCompleted;
  final int totalFiles;
  final int completedFiles;
  final int failedFiles;
  final int totalBytes;
  final int copiedBytes;
  final bool resumeOnLaunch;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastError;

  bool get isActive =>
      status == CopyTaskStatus.running || status == CopyTaskStatus.scanning;

  bool get canResume =>
      status == CopyTaskStatus.paused ||
      status == CopyTaskStatus.failed ||
      status == CopyTaskStatus.queued;

  double get progress {
    if (totalBytes <= 0) {
      return status == CopyTaskStatus.completed ? 1 : 0;
    }
    return (copiedBytes / totalBytes).clamp(0, 1);
  }

  factory CopyTask.fromMap(Map<String, Object?> map) {
    return CopyTask(
      id: map['id']! as int,
      name: map['name']! as String,
      sourceDir: map['source_dir']! as String,
      targetDir: map['target_dir']! as String,
      workerCount: map['worker_count']! as int,
      sourceBookmark: map['source_bookmark'] as String?,
      targetBookmark: map['target_bookmark'] as String?,
      status: copyTaskStatusFromDb(map['status']! as String),
      scanCompleted: (map['scan_completed']! as int) == 1,
      totalFiles: map['total_files']! as int,
      completedFiles: map['completed_files']! as int,
      failedFiles: map['failed_files']! as int,
      totalBytes: map['total_bytes']! as int,
      copiedBytes: map['copied_bytes']! as int,
      resumeOnLaunch: (map['resume_on_launch']! as int) == 1,
      lastError: map['last_error'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
    );
  }
}

class CopyEntry {
  const CopyEntry({
    required this.id,
    required this.taskId,
    required this.relativePath,
    required this.size,
    required this.modifiedMs,
    required this.status,
    required this.bytesCopied,
    required this.updatedAt,
    this.sourceMd5,
    this.error,
  });

  final int id;
  final int taskId;
  final String relativePath;
  final int size;
  final int modifiedMs;
  final CopyEntryStatus status;
  final int bytesCopied;
  final DateTime updatedAt;
  final String? sourceMd5;
  final String? error;

  double get progress {
    if (size <= 0) {
      return status == CopyEntryStatus.completed ? 1 : 0;
    }
    return (bytesCopied / size).clamp(0, 1);
  }

  factory CopyEntry.fromMap(Map<String, Object?> map) {
    return CopyEntry(
      id: map['id']! as int,
      taskId: map['task_id']! as int,
      relativePath: map['relative_path']! as String,
      size: map['size']! as int,
      modifiedMs: map['modified_ms']! as int,
      status: copyEntryStatusFromDb(map['status']! as String),
      bytesCopied: map['bytes_copied']! as int,
      sourceMd5: map['source_md5'] as String?,
      error: map['error'] as String?,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
    );
  }
}

class CopyChunk {
  const CopyChunk({
    required this.entryId,
    required this.chunkIndex,
    required this.chunkSize,
    required this.md5,
  });

  final int entryId;
  final int chunkIndex;
  final int chunkSize;
  final String md5;

  factory CopyChunk.fromMap(Map<String, Object?> map) {
    return CopyChunk(
      entryId: map['entry_id']! as int,
      chunkIndex: map['chunk_index']! as int,
      chunkSize: map['chunk_size']! as int,
      md5: map['md5']! as String,
    );
  }
}

class ScannedEntryDraft {
  const ScannedEntryDraft({
    required this.relativePath,
    required this.size,
    required this.modifiedMs,
  });

  final String relativePath;
  final int size;
  final int modifiedMs;
}
