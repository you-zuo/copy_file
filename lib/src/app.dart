import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'data/models.dart';
import 'viewmodels/task_list_view_model.dart';

class CopyFileBootstrap extends StatefulWidget {
  const CopyFileBootstrap({super.key});

  @override
  State<CopyFileBootstrap> createState() => _CopyFileBootstrapState();
}

class _CopyFileBootstrapState extends State<CopyFileBootstrap>
    with WindowListener {
  bool _closing = false;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      windowManager.addListener(this);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TaskListViewModel>().initialize();
    });
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowFocus() {
    unawaited(_syncHardwareKeyboardState());
  }

  @override
  Future<void> onWindowClose() async {
    if (_closing) {
      await windowManager.destroy();
      return;
    }

    final viewModel = context.read<TaskListViewModel>();
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) {
      return;
    }
    final shouldClose =
        await showDialog<bool>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: Text(viewModel.hasActiveTasks ? '退出前暂停任务' : '确认退出应用'),
            content: Text(
              viewModel.hasActiveTasks
                  ? '当前还有复制任务在运行。关闭窗口会先暂停任务，并在下次启动时自动恢复。是否继续退出？'
                  : '关闭窗口后会退出应用。是否继续？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('退出'),
              ),
            ],
          ),
        ) ??
        false;

    if (!shouldClose) {
      return;
    }

    _closing = true;
    await viewModel.prepareForShutdown();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Copy File',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A6E57),
          surface: const Color(0xFFF4F0E8),
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F2EA),
        useMaterial3: true,
      ),
      home: const CopyFileHomePage(),
    );
  }
}

class CopyFileHomePage extends StatelessWidget {
  const CopyFileHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskListViewModel>(
      builder: (context, viewModel, _) {
        if (!viewModel.isReady && viewModel.isBusy) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('桌面文件复制'),
            centerTitle: false,
            actions: [
              IconButton(
                tooltip: '刷新',
                onPressed: () => viewModel.refresh(),
                icon: const Icon(Icons.refresh),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: FilledButton.icon(
                  onPressed: () async {
                    final result = await showDialog<_TaskDraftResult>(
                      context: context,
                      builder: (_) => const _TaskEditorDialog(),
                    );
                    if (result == null) {
                      return;
                    }
                    await viewModel.createTask(
                      name: result.name,
                      sourceDir: result.sourceDir,
                      targetDir: result.targetDir,
                      workerCount: result.workerCount,
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('新建任务'),
                ),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (viewModel.message case final message?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Material(
                      color: const Color(0xFFF5DDD2),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(message),
                      ),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 1000;
                      if (compact) {
                        return Column(
                          children: [
                            Expanded(
                              flex: 11,
                              child: _TaskListPanel(tasks: viewModel.tasks),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              flex: 13,
                              child: _TaskDetailPanel(
                                task: viewModel.selectedTask,
                                entries: viewModel.selectedEntries,
                              ),
                            ),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(
                            flex: 11,
                            child: _TaskListPanel(tasks: viewModel.tasks),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 13,
                            child: _TaskDetailPanel(
                              task: viewModel.selectedTask,
                              entries: viewModel.selectedEntries,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TaskListPanel extends StatelessWidget {
  const _TaskListPanel({required this.tasks});

  final List<CopyTask> tasks;

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<TaskListViewModel>();
    final selectedTaskId = viewModel.selectedTask?.id;
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('任务列表', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '任务状态会写入本地 SQLite，窗口关闭后下次仍可恢复。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonalIcon(
                  onPressed: viewModel.hasResumableTasks
                      ? () => viewModel.resumeAllTasks()
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('全部开始'),
                ),
                OutlinedButton.icon(
                  onPressed: viewModel.hasPausableTasks
                      ? () => viewModel.pauseAllTasks()
                      : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('全部暂停'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (tasks.isEmpty)
              const Expanded(child: Center(child: Text('还没有复制任务')))
            else
              Expanded(
                child: ListView.separated(
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final selected = task.id == selectedTaskId;
                    return InkWell(
                      onTap: () =>
                          context.read<TaskListViewModel>().selectTask(task.id),
                      borderRadius: BorderRadius.circular(18),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFDFEFE9)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF0A6E57)
                                : const Color(0xFFD7D1C8),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    task.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                _StatusChip(status: task.status),
                              ],
                            ),
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              value: task.progress,
                              minHeight: 10,
                              borderRadius: BorderRadius.circular(999),
                              backgroundColor: const Color(0xFFE7E1D8),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '${formatBytes(task.copiedBytes)} / ${formatBytes(task.totalBytes)}',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '文件 ${task.completedFiles}/${task.totalFiles}'
                              '${task.failedFiles > 0 ? ' · 失败 ${task.failedFiles}' : ''}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              task.sourceDir,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TaskDetailPanel extends StatelessWidget {
  const _TaskDetailPanel({required this.task, required this.entries});

  final CopyTask? task;
  final List<CopyEntry> entries;

  @override
  Widget build(BuildContext context) {
    final currentTask = task;
    if (currentTask == null) {
      return DecoratedBox(
        decoration: _panelDecoration(),
        child: const Center(child: Text('请选择左侧任务')),
      );
    }

    final viewModel = context.read<TaskListViewModel>();
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  currentTask.name,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                _StatusChip(status: currentTask.status),
                FilledButton.tonalIcon(
                  onPressed: currentTask.canResume
                      ? () => viewModel.resumeTask(currentTask.id)
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('继续'),
                ),
                OutlinedButton.icon(
                  onPressed: currentTask.isActive
                      ? () => viewModel.pauseTask(currentTask.id)
                      : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('暂停'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final result = await showDialog<_TaskDraftResult>(
                      context: context,
                      builder: (_) => _TaskEditorDialog(task: currentTask),
                    );
                    if (result == null || !context.mounted) {
                      return;
                    }
                    await viewModel.editTask(
                      taskId: currentTask.id,
                      name: result.name,
                      sourceDir: result.sourceDir,
                      targetDir: result.targetDir,
                      workerCount: result.workerCount,
                    );
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑任务'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('删除任务'),
                        content: Text(
                          currentTask.isActive
                              ? '删除任务会先停止当前复制，并清空该任务的数据库记录和断点进度。已经复制到目标目录的文件不会被删除。是否继续？'
                              : '删除任务会清空该任务的数据库记录和断点进度。已经复制到目标目录的文件不会被删除。是否继续？',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF8D3E25),
                            ),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !context.mounted) {
                      return;
                    }
                    await viewModel.deleteTask(currentTask.id);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除任务'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: currentTask.progress,
              minHeight: 12,
              borderRadius: BorderRadius.circular(999),
              backgroundColor: const Color(0xFFE7E1D8),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 10,
              children: [
                _InfoTag(
                  label: '已复制',
                  value: formatBytes(currentTask.copiedBytes),
                ),
                _InfoTag(
                  label: '总大小',
                  value: formatBytes(currentTask.totalBytes),
                ),
                _InfoTag(
                  label: '文件数',
                  value:
                      '${currentTask.completedFiles}/${currentTask.totalFiles}',
                ),
                _InfoTag(
                  label: '最近更新',
                  value: formatDateTime(currentTask.updatedAt),
                ),
                _InfoTag(label: '并发数', value: '${currentTask.workerCount}'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('任务并发', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<int>(
                    initialValue: currentTask.workerCount,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: List<DropdownMenuItem<int>>.generate(
                      8,
                      (index) => DropdownMenuItem<int>(
                        value: index + 1,
                        child: Text('${index + 1}'),
                      ),
                    ),
                    onChanged: currentTask.isActive
                        ? null
                        : (value) {
                            if (value == null ||
                                value == currentTask.workerCount) {
                              return;
                            }
                            viewModel.updateTaskWorkerCount(
                              currentTask.id,
                              value,
                            );
                          },
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  currentTask.isActive ? '请先暂停任务再修改' : '暂停时可修改',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('源目录', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(currentTask.sourceDir),
            const SizedBox(height: 10),
            Text('目标目录', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(currentTask.targetDir),
            if (currentTask.lastError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Material(
                  color: const Color(0xFFF5DDD2),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(error),
                  ),
                ),
              ),
            const SizedBox(height: 18),
            Text('最近文件状态', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('扫描完成后会显示文件进度'))
                  : ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 4,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 8,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.relativePath,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${formatBytes(entry.bytesCopied)} / ${formatBytes(entry.size)}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                    if (entry.error case final error?)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          error,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: const Color(0xFF8D3E25),
                                              ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 3,
                                child: LinearProgressIndicator(
                                  value: entry.progress,
                                  minHeight: 8,
                                  borderRadius: BorderRadius.circular(999),
                                  backgroundColor: const Color(0xFFE7E1D8),
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 88,
                                child: Text(
                                  entry.status.name,
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskEditorDialog extends StatefulWidget {
  const _TaskEditorDialog({this.task});

  final CopyTask? task;

  @override
  State<_TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<_TaskEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _sourceController;
  late final TextEditingController _targetController;
  late int _workerCount;
  String? _error;

  bool get _isEditing => widget.task != null;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _nameController = TextEditingController(text: task?.name ?? '');
    _sourceController = TextEditingController(text: task?.sourceDir ?? '');
    _targetController = TextEditingController(text: task?.targetDir ?? '');
    _workerCount =
        task?.workerCount ??
        context.read<TaskListViewModel>().defaultWorkerCount;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _sourceController.dispose();
    _targetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? '编辑复制任务' : '新建复制任务'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '任务名称',
                hintText: '例如：影像资料归档',
              ),
            ),
            const SizedBox(height: 12),
            _PathField(
              controller: _sourceController,
              label: '源目录',
              buttonText: '选择源目录',
            ),
            const SizedBox(height: 12),
            _PathField(
              controller: _targetController,
              label: '目标目录',
              buttonText: '选择目标目录',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _workerCount,
              decoration: const InputDecoration(labelText: '任务并发数'),
              items: List<DropdownMenuItem<int>>.generate(
                8,
                (index) => DropdownMenuItem<int>(
                  value: index + 1,
                  child: Text('${index + 1}'),
                ),
              ),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() {
                  _workerCount = value;
                });
              },
            ),
            if (_isEditing)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '保存后会重置当前任务的扫描结果和断点进度，并按新的目录重新开始。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF5F5545),
                    ),
                  ),
                ),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF8D3E25),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_isEditing ? '保存修改' : '创建并开始'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final sourceDir = p.normalize(_sourceController.text.trim());
    final targetDir = p.normalize(_targetController.text.trim());
    final name = _nameController.text.trim().isEmpty
        ? p.basename(sourceDir)
        : _nameController.text.trim();

    if (sourceDir.isEmpty || targetDir.isEmpty) {
      setState(() {
        _error = '请先选择源目录和目标目录';
      });
      return;
    }

    if (sourceDir == targetDir ||
        p.isWithin(sourceDir, targetDir) ||
        p.isWithin(targetDir, sourceDir)) {
      setState(() {
        _error = '源目录和目标目录不能重叠';
      });
      return;
    }

    if (!await Directory(sourceDir).exists()) {
      setState(() {
        _error = '源目录不存在';
      });
      return;
    }

    await Directory(targetDir).create(recursive: true);

    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(
      _TaskDraftResult(
        name: name,
        sourceDir: sourceDir,
        targetDir: targetDir,
        workerCount: _workerCount,
      ),
    );
  }
}

class _PathField extends StatelessWidget {
  const _PathField({
    required this.controller,
    required this.label,
    required this.buttonText,
  });

  final TextEditingController controller;
  final String label;
  final String buttonText;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(labelText: label),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: () async {
            try {
              FocusManager.instance.primaryFocus?.unfocus();
              await _syncHardwareKeyboardState();
              final directory = await getDirectoryPath();
              await _syncHardwareKeyboardState();
              if (directory == null) {
                return;
              }
              controller.text = directory;
            } catch (error) {
              await _syncHardwareKeyboardState();
              if (!context.mounted) {
                return;
              }
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('打开目录选择器失败: $error')));
            }
          },
          child: Text(buttonText),
        ),
      ],
    );
  }
}

class _InfoTag extends StatelessWidget {
  const _InfoTag({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD7D1C8)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: RichText(
          text: TextSpan(
            style: Theme.of(context).textTheme.bodyMedium,
            children: [
              TextSpan(
                text: '$label ',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF43514D),
                ),
              ),
              TextSpan(
                text: value,
                style: const TextStyle(color: Color(0xFF121A18)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final CopyTaskStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = switch (status) {
      CopyTaskStatus.running => (
        const Color(0xFFD9EFE0),
        const Color(0xFF0E6D52),
      ),
      CopyTaskStatus.scanning => (
        const Color(0xFFF7E9C9),
        const Color(0xFF8A5A00),
      ),
      CopyTaskStatus.completed => (
        const Color(0xFFDCE7FF),
        const Color(0xFF2150A5),
      ),
      CopyTaskStatus.failed => (
        const Color(0xFFF5DDD2),
        const Color(0xFF8D3E25),
      ),
      CopyTaskStatus.paused => (
        const Color(0xFFE9E3D8),
        const Color(0xFF5F5545),
      ),
      CopyTaskStatus.queued => (
        const Color(0xFFE9E3D8),
        const Color(0xFF5F5545),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.$1,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.name,
        style: TextStyle(color: palette.$2, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _TaskDraftResult {
  const _TaskDraftResult({
    required this.name,
    required this.sourceDir,
    required this.targetDir,
    required this.workerCount,
  });

  final String name;
  final String sourceDir;
  final String targetDir;
  final int workerCount;
}

BoxDecoration _panelDecoration() {
  return BoxDecoration(
    color: const Color(0xFFF9F6EF),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: const Color(0xFFD7D1C8)),
    boxShadow: const [
      BoxShadow(
        color: Color(0x14000000),
        blurRadius: 18,
        offset: Offset(0, 10),
      ),
    ],
  );
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  if (bytes <= 0) {
    return '0 B';
  }
  var size = bytes.toDouble();
  var unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  final digits = size >= 100 ? 0 : (size >= 10 ? 1 : 2);
  return '${size.toStringAsFixed(digits)} ${units[unitIndex]}';
}

String formatDateTime(DateTime dateTime) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${dateTime.year}-${twoDigits(dateTime.month)}-${twoDigits(dateTime.day)} '
      '${twoDigits(dateTime.hour)}:${twoDigits(dateTime.minute)}';
}

bool get _isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

Future<void> _syncHardwareKeyboardState() async {
  try {
    await HardwareKeyboard.instance.syncKeyboardState();
  } catch (_) {
    // Best-effort workaround for desktop keyboard state desync after native dialogs.
  }
}
