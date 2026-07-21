import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:path_provider/path_provider.dart';

/// The active camera rig. Read this at analysis time (offline viewer + live
/// workout) to pick the matching tuning profile. Defaults to [RecordingMode
/// .tripod] — the recommended, cleanest-geometry setup.
final recordingModeNotifier =
    ValueNotifier<RecordingMode>(RecordingMode.tripod);

/// Persists the selected [RecordingMode] to the app documents directory,
/// mirroring [ThemeStorage] / [LiveFeedbackPrefs].
class RecordingModeStorage {
  static const _fileName = 'recording_mode.txt';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> load() async {
    try {
      final file = await _getFile();
      if (!file.existsSync()) return;
      final value = file.readAsStringSync().trim();
      recordingModeNotifier.value = RecordingModeInfo.fromStorageKey(value);
    } catch (_) {}
  }

  static Future<void> save(RecordingMode mode) async {
    try {
      final file = await _getFile();
      await file.writeAsString(mode.storageKey);
    } catch (_) {}
  }

  /// Update the notifier and persist in one call.
  static void set(RecordingMode mode) {
    recordingModeNotifier.value = mode;
    save(mode);
  }
}
