import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';

class DirectoryAccessService {
  static const MethodChannel _channel = MethodChannel(
    'copy_file/security_scoped_bookmarks',
  );

  final Map<int, List<String>> _activeTaskTokens = <int, List<String>>{};

  bool get _needsSecurityScopedAccess => !kIsWeb && Platform.isMacOS;

  Future<String?> createBookmarkForPath(String path) async {
    if (!_needsSecurityScopedAccess) {
      return null;
    }

    final bookmark = await _channel.invokeMethod<String>(
      'createBookmark',
      <String, Object?>{'path': path},
    );
    return bookmark;
  }

  Future<void> activateTask(CopyTask task) async {
    if (!_needsSecurityScopedAccess) {
      return;
    }
    if (_activeTaskTokens.containsKey(task.id)) {
      return;
    }

    final sourceBookmark = task.sourceBookmark;
    final targetBookmark = task.targetBookmark;
    if (sourceBookmark == null || targetBookmark == null) {
      throw Exception('该任务缺少 macOS 目录授权，请删除后重新创建任务。');
    }

    final tokens = <String>[];
    try {
      tokens.add(await _startAccess(sourceBookmark));
      tokens.add(await _startAccess(targetBookmark));
      _activeTaskTokens[task.id] = tokens;
    } catch (error) {
      for (final token in tokens) {
        await _stopAccess(token);
      }
      rethrow;
    }
  }

  Future<void> deactivateTask(int taskId) async {
    final tokens = _activeTaskTokens.remove(taskId);
    if (tokens == null) {
      return;
    }

    for (final token in tokens) {
      await _stopAccess(token);
    }
  }

  Future<void> deactivateAll() async {
    final taskIds = _activeTaskTokens.keys.toList(growable: false);
    for (final taskId in taskIds) {
      await deactivateTask(taskId);
    }
  }

  Future<String> _startAccess(String bookmark) async {
    final token = await _channel.invokeMethod<String>(
      'startAccess',
      <String, Object?>{'bookmark': bookmark},
    );
    if (token == null || token.isEmpty) {
      throw Exception('无法恢复 macOS 目录授权');
    }
    return token;
  }

  Future<void> _stopAccess(String token) async {
    if (!_needsSecurityScopedAccess) {
      return;
    }
    await _channel.invokeMethod<void>('stopAccess', <String, Object?>{
      'token': token,
    });
  }
}
