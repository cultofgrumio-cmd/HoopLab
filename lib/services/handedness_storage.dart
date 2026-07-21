import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooplab/models/handedness.dart';
import 'package:path_provider/path_provider.dart';

/// The player's shooting hand. Read this wherever guidance/analysis needs to be
/// oriented per side. Defaults to [Handedness.right].
final handednessNotifier = ValueNotifier<Handedness>(Handedness.right);

/// Persists the selected [Handedness] to the app documents directory, mirroring
/// [RecordingModeStorage] / [ThemeStorage].
class HandednessStorage {
  static const _fileName = 'handedness.txt';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> load() async {
    try {
      final file = await _getFile();
      if (!file.existsSync()) return;
      final value = file.readAsStringSync().trim();
      handednessNotifier.value = HandednessInfo.fromStorageKey(value);
    } catch (_) {}
  }

  static Future<void> save(Handedness hand) async {
    try {
      final file = await _getFile();
      await file.writeAsString(hand.storageKey);
    } catch (_) {}
  }

  /// Update the notifier and persist in one call.
  static void set(Handedness hand) {
    handednessNotifier.value = hand;
    save(hand);
  }
}
