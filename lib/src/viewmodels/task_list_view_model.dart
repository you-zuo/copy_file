import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/copy_repository.dart';
import '../data/models.dart';
import '../services/copy_engine_client.dart';
import '../services/directory_access_service.dart';
import '../services/sleep_blocker_service.dart';

class TaskListViewModel extends ChangeNotifier {
  TaskListViewModel({
    required CopyRepository repository,
    required CopyEngineClient engine,
    required DirectoryAccessService directoryAccessService,
    required SleepBlockerService sleepBlockerService,
  }) : _repository = repository,
       _engine = engine,
       _directoryAccessService = directoryAccessService,
       _sleepBlockerService = sleepBlockerService;

  final CopyRepository _repository;
  final CopyEngineClient _engine;
  final DirectoryAccessService _directoryAccessService;
  final SleepBlockerService _sleepBlockerService;

  List<CopyTask> _tasks = const <CopyTask>[];
  List<CopyEntry> _selectedEntries = const <CopyEntry>[];
  int? _selectedTaskId;
  bool _isInitializing = false;
  bool _isReady = false;
  String? _message;
  StreamSubscription<int?>? _repositorySubscription;
  StreamSubscription<int?>? _engineSubscription;
  Timer? _reloadThrottle;
  bool _isRefreshing = false;
  bool _hasQueuedRefresh = false;
  bool _queuedRefreshSilent = true;
  Completer<void>? _queuedRefreshCompleter;

  List<CopyTask> get tasks => _tasks;
  List<CopyEntry> get selectedEntries => _selectedEntries;
  bool get isReady => _isReady;
  bool get isBusy => _isInitializing;
  String? get message => _message;
  int? get selectedTaskId => _selectedTaskId;

  CopyTask? get selectedTask {
    if (_selectedTaskId == null) {
      return _tasks.isEmpty ? null : _tasks.first;
    }
    for (final task in _tasks) {
      if (task.id == _selectedTaskId) {
        return task;
      }
    }
    return _tasks.isEmpty ? null : _tasks.first;
  }

  bool get hasActiveTasks =>
      _engine.hasActiveTasks || _tasks.any((task) => task.isActive);

  Future<void> initialize() async {
    if (_isReady || _isInitializing) {
      return;
    }
    _isInitializing = true;
    notifyListeners();

    try {
      await _repository.initialize();
      _repositorySubscription = _repository.changes.listen((_) {
        _scheduleRefresh();
      });
      _engineSubscription = _engine.taskChanges.listen((_) {
        _scheduleRefresh();
      });

      final interruptedTaskIds = await _repository.recoverInterruptedTasks();
      await refresh(silent: true);
      for (final taskId in interruptedTaskIds) {
        unawaited(
          _resumeTaskExecution(taskId).catchError((Object error) {
            _message = error.toString();
            notifyListeners();
          }),
        );
      }
      _isReady = true;
    } catch (error) {
      _message = error.toString();
    } finally {
      _isInitializing = false;
      notifyListeners();
      unawaited(_syncSleepBlocker());
    }
  }

  void _scheduleRefresh() {
    if (_reloadThrottle?.isActive ?? false) {
      return;
    }
    _reloadThrottle = Timer(const Duration(milliseconds: 250), () {
      _reloadThrottle = null;
      unawaited(refresh(silent: true));
    });
  }

  Future<void> refresh({bool silent = false}) async {
    if (_isRefreshing) {
      _hasQueuedRefresh = true;
      _queuedRefreshSilent = _queuedRefreshSilent && silent;
      return (_queuedRefreshCompleter ??= Completer<void>()).future;
    }

    Object? refreshError;
    StackTrace? refreshStackTrace;
    _isRefreshing = true;
    try {
      await _refreshNow(silent: silent);
    } catch (error, stackTrace) {
      refreshError = error;
      refreshStackTrace = stackTrace;
    } finally {
      _isRefreshing = false;
    }

    if (_hasQueuedRefresh) {
      final completer = _queuedRefreshCompleter;
      final queuedSilent = _queuedRefreshSilent;
      _hasQueuedRefresh = false;
      _queuedRefreshSilent = true;
      _queuedRefreshCompleter = null;
      try {
        await refresh(silent: queuedSilent);
        completer?.complete();
      } catch (error, stackTrace) {
        completer?.completeError(error, stackTrace);
        if (refreshError == null) {
          refreshError = error;
          refreshStackTrace = stackTrace;
        }
      }
    }

    if (refreshError != null) {
      Error.throwWithStackTrace(refreshError, refreshStackTrace!);
    }
  }

  Future<void> _refreshNow({required bool silent}) async {
    if (!silent) {
      _message = null;
    }

    final tasks = await _repository.listTasks();
    _tasks = tasks;
    if (_selectedTaskId == null && tasks.isNotEmpty) {
      _selectedTaskId = tasks.first.id;
    } else if (_selectedTaskId != null &&
        tasks.every((task) => task.id != _selectedTaskId)) {
      _selectedTaskId = tasks.isEmpty ? null : tasks.first.id;
    }

    if (_selectedTaskId != null) {
      _selectedEntries = await _repository.listEntries(_selectedTaskId!);
    } else {
      _selectedEntries = const <CopyEntry>[];
    }
    notifyListeners();
    await _syncSleepBlocker();
  }

  Future<void> selectTask(int taskId) async {
    _selectedTaskId = taskId;
    await refresh(silent: true);
  }

  Future<void> createTask({
    required String name,
    required String sourceDir,
    required String targetDir,
  }) async {
    _message = null;
    notifyListeners();
    try {
      final sourceBookmark = await _directoryAccessService
          .createBookmarkForPath(sourceDir);
      final targetBookmark = await _directoryAccessService
          .createBookmarkForPath(targetDir);
      final taskId = await _repository.createTask(
        name: name,
        sourceDir: sourceDir,
        targetDir: targetDir,
        sourceBookmark: sourceBookmark,
        targetBookmark: targetBookmark,
      );
      _selectedTaskId = taskId;
      await refresh(silent: true);
      await _resumeTaskExecution(taskId);
      await _syncSleepBlocker();
    } catch (error) {
      _message = error.toString();
      notifyListeners();
    }
  }

  Future<void> editTask({
    required int taskId,
    required String name,
    required String sourceDir,
    required String targetDir,
  }) async {
    _message = null;
    notifyListeners();
    try {
      final task = await _repository.getTask(taskId);
      if (task == null) {
        await refresh(silent: true);
        return;
      }

      final nameChanged = task.name != name;
      final directoriesChanged =
          task.sourceDir != sourceDir || task.targetDir != targetDir;
      if (!nameChanged && !directoriesChanged) {
        return;
      }

      if (!directoriesChanged) {
        await _repository.updateTaskDefinition(
          taskId: taskId,
          name: name,
          sourceDir: task.sourceDir,
          targetDir: task.targetDir,
          resetProgress: false,
        );
        await refresh(silent: true);
        return;
      }

      final shouldResumeAfterEdit = task.isActive;
      if (task.isActive) {
        await _engine.pauseTask(taskId);
      }
      await _directoryAccessService.deactivateTask(taskId);

      final sourceBookmark = await _directoryAccessService
          .createBookmarkForPath(sourceDir);
      final targetBookmark = await _directoryAccessService
          .createBookmarkForPath(targetDir);
      final resetStatus = switch (task.status) {
        CopyTaskStatus.running ||
        CopyTaskStatus.scanning => CopyTaskStatus.queued,
        CopyTaskStatus.queued => CopyTaskStatus.queued,
        _ => CopyTaskStatus.paused,
      };

      await _repository.updateTaskDefinition(
        taskId: taskId,
        name: name,
        sourceDir: sourceDir,
        targetDir: targetDir,
        sourceBookmark: sourceBookmark,
        targetBookmark: targetBookmark,
        resetProgress: true,
        status: resetStatus,
      );
      _selectedTaskId = taskId;
      await refresh(silent: true);

      if (shouldResumeAfterEdit) {
        await _resumeTaskExecution(taskId);
        await refresh(silent: true);
      }
      await _syncSleepBlocker();
    } catch (error) {
      _message = error.toString();
      notifyListeners();
    }
  }

  Future<void> pauseTask(int taskId) async {
    _message = null;
    notifyListeners();
    try {
      await _engine.pauseTask(taskId);
      await _directoryAccessService.deactivateTask(taskId);
      await refresh(silent: true);
      await _syncSleepBlocker();
    } catch (error) {
      _message = error.toString();
      notifyListeners();
    }
  }

  Future<void> resumeTask(int taskId) async {
    _message = null;
    notifyListeners();
    try {
      await _resumeTaskExecution(taskId);
      await refresh(silent: true);
      await _syncSleepBlocker();
    } catch (error) {
      _message = error.toString();
      notifyListeners();
    }
  }

  Future<void> deleteTask(int taskId) async {
    _message = null;
    notifyListeners();
    try {
      final task = await _repository.getTask(taskId);
      if (task == null) {
        await refresh(silent: true);
        return;
      }
      if (task.isActive) {
        await _engine.pauseTask(taskId);
      }
      await _directoryAccessService.deactivateTask(taskId);
      await _repository.deleteTask(taskId);
      if (_selectedTaskId == taskId) {
        _selectedTaskId = null;
      }
      await refresh(silent: true);
      await _syncSleepBlocker();
    } catch (error) {
      _message = error.toString();
      notifyListeners();
    }
  }

  Future<void> prepareForShutdown() async {
    await _engine.pauseAllForShutdown();
    await _directoryAccessService.deactivateAll();
    await refresh(silent: true);
    await _syncSleepBlocker();
  }

  Future<void> _resumeTaskExecution(int taskId) async {
    final task = await _repository.getTask(taskId);
    if (task == null) {
      return;
    }
    await _directoryAccessService.activateTask(task);
    await _engine.startTask(taskId);
  }

  Future<void> _syncSleepBlocker() {
    return _sleepBlockerService.setActive(hasActiveTasks);
  }

  @override
  void dispose() {
    _reloadThrottle?.cancel();
    _repositorySubscription?.cancel();
    _engineSubscription?.cancel();
    unawaited(_sleepBlockerService.dispose());
    unawaited(_directoryAccessService.deactivateAll());
    unawaited(_engine.dispose());
    unawaited(_repository.dispose());
    super.dispose();
  }
}
