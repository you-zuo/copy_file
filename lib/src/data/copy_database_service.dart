import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class CopyDatabaseService {
  CopyDatabaseService({required this.databasePath});

  final String databasePath;
  Database? _database;

  Future<Database> open() async {
    if (_database != null && _database!.isOpen) {
      return _database!;
    }

    _database = await databaseFactory.openDatabase(
      p.normalize(databasePath),
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
          await db.execute('PRAGMA temp_store = MEMORY');
          await db.execute('PRAGMA cache_size = -65536');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE copy_tasks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              source_dir TEXT NOT NULL,
              target_dir TEXT NOT NULL,
              worker_count INTEGER NOT NULL DEFAULT 4,
              source_bookmark TEXT,
              target_bookmark TEXT,
              status TEXT NOT NULL,
              scan_completed INTEGER NOT NULL DEFAULT 0,
              total_files INTEGER NOT NULL DEFAULT 0,
              completed_files INTEGER NOT NULL DEFAULT 0,
              failed_files INTEGER NOT NULL DEFAULT 0,
              total_bytes INTEGER NOT NULL DEFAULT 0,
              copied_bytes INTEGER NOT NULL DEFAULT 0,
              resume_on_launch INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE copy_entries (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id INTEGER NOT NULL,
              relative_path TEXT NOT NULL,
              size INTEGER NOT NULL,
              modified_ms INTEGER NOT NULL,
              status TEXT NOT NULL,
              bytes_copied INTEGER NOT NULL DEFAULT 0,
              source_md5 TEXT,
              error TEXT,
              updated_at INTEGER NOT NULL,
              FOREIGN KEY(task_id) REFERENCES copy_tasks(id) ON DELETE CASCADE
            )
          ''');
          await db.execute('''
            CREATE TABLE copy_chunks (
              entry_id INTEGER NOT NULL,
              chunk_index INTEGER NOT NULL,
              chunk_size INTEGER NOT NULL,
              md5 TEXT NOT NULL,
              PRIMARY KEY(entry_id, chunk_index),
              FOREIGN KEY(entry_id) REFERENCES copy_entries(id) ON DELETE CASCADE
            )
          ''');
          await db.execute(
            'CREATE UNIQUE INDEX idx_copy_entries_task_path ON copy_entries(task_id, relative_path)',
          );
          await db.execute(
            'CREATE INDEX idx_copy_entries_task_status ON copy_entries(task_id, status)',
          );
          await db.execute(
            'CREATE INDEX idx_copy_entries_task_updated ON copy_entries(task_id, updated_at DESC)',
          );
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE copy_tasks ADD COLUMN source_bookmark TEXT',
            );
            await db.execute(
              'ALTER TABLE copy_tasks ADD COLUMN target_bookmark TEXT',
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              'ALTER TABLE copy_tasks ADD COLUMN worker_count INTEGER NOT NULL DEFAULT 4',
            );
          }
        },
      ),
    );
    return _database!;
  }

  Future<void> close() async {
    final database = _database;
    if (database == null || !database.isOpen) {
      _database = null;
      return;
    }

    await database.close();
    _database = null;
  }
}
