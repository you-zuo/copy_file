import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/data/copy_database_service.dart';
import 'src/data/copy_repository.dart';
import 'src/services/copy_engine_client.dart';
import 'src/services/directory_access_service.dart';
import 'src/services/sleep_blocker_service.dart';
import 'src/viewmodels/task_list_view_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1380, 860),
      minimumSize: Size(1120, 720),
      center: true,
      title: 'Copy File',
      backgroundColor: Colors.transparent,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final appSupportDirectory = await getApplicationSupportDirectory();
  final databaseService = CopyDatabaseService(
    databasePath:
        '${appSupportDirectory.path}${Platform.pathSeparator}copy_file.db',
  );
  final repository = CopyRepository(databaseService);
  final directoryAccessService = DirectoryAccessService();
  final sleepBlockerService = SleepBlockerService();
  final engine = CopyEngineClient(
    databasePath:
        '${appSupportDirectory.path}${Platform.pathSeparator}copy_file.db',
    workerCount: 2,
  );
  await engine.initialize();
  final viewModel = TaskListViewModel(
    repository: repository,
    engine: engine,
    directoryAccessService: directoryAccessService,
    sleepBlockerService: sleepBlockerService,
  );

  runApp(
    MultiProvider(
      providers: [
        Provider<CopyRepository>.value(value: repository),
        Provider<CopyEngineClient>.value(value: engine),
        Provider<DirectoryAccessService>.value(value: directoryAccessService),
        Provider<SleepBlockerService>.value(value: sleepBlockerService),
        ChangeNotifierProvider<TaskListViewModel>.value(value: viewModel),
      ],
      child: const CopyFileBootstrap(),
    ),
  );
}

bool get _isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
