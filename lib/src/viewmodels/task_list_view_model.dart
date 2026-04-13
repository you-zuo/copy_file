import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/copy_repository.dart';
import '../data/models.dart';
import '../services/copy_engine_client.dart';

class TaskListViewModel extends ChangeNotifier {
  TaskListViewModel({
    required CopyRepository repository,
    required CopyEngineClient engine,
  }) : _repository = repository,
       _engine = engine;

  final CopyRepository _repository;
  final CopyEngineClient _engine;

  List<CopyTask> _tasks = const <CopyTask>[];
  List<CopyEntry> _selectedEntries = const <CopyEntry>[];
  int? _selectedTaskId;
  bool _isInitializing = false;
  bool _isReady = false;
  String? _message;
  StreamSubscription<int?>? _repositorySubscription;
  StreamSubscription<int?>? _engineSubscription;
  Timer? _reloadDebounce;

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
        unawaited(_engine.startTask(taskId));
      }
      _isReady = true;
    } catch (error) {
      _message = error.toString();
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  void _scheduleRefresh() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(refresh(silent: true)),
    );
  }

  Future<void> refresh({bool silent = false}) async {
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
      final taskId = await _repository.createTask(
        name: name,
        sourceDir: sourceDir,
        targetDir: targetDir,
      );
      _selectedTaskId = taskId;
      await refresh(silent: true);
      unawaited(_engine.startTask(taskId));
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
      await refresh(silent: true);
    } catch (error) {
      _message = error.toString();
      notifyListeners();
    }
  }

  Future<void> resumeTask(int taskId) async {
    _message = null;
    notifyListeners();
    try {
      unawaited(_engine.startTask(taskId));
      await refresh(silent: true);
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
      await _repository.deleteTask(taskId);
      if (_selectedTaskId == taskId) {
        _selectedTaskId = null;
      }
      await refresh(silent: true);
    } catch (error) {
      _message = error.toString();
      notifyListeners();
    }
  }

  Future<void> prepareForShutdown() async {
    await _engine.pauseAllForShutdown();
    await refresh(silent: true);
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _repositorySubscription?.cancel();
    _engineSubscription?.cancel();
    unawaited(_engine.dispose());
    unawaited(_repository.dispose());
    super.dispose();
  }
}
