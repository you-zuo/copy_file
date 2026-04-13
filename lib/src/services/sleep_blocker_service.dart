import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SleepBlockerService {
  static const MethodChannel _channel = MethodChannel(
    'copy_file/sleep_blocker',
  );

  bool _isActive = false;

  bool get _supportsSleepBlocker => !kIsWeb && Platform.isMacOS;

  Future<void> setActive(bool active) async {
    if (!_supportsSleepBlocker || _isActive == active) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('setActive', <String, Object?>{
        'active': active,
      });
      _isActive = active;
    } catch (error) {
      debugPrint('Failed to toggle sleep blocker: $error');
    }
  }

  Future<void> dispose() async {
    await setActive(false);
  }
}
