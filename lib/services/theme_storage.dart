import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

final themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

class ThemeStorage {
  static const _fileName = 'theme_mode.txt';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> load() async {
    try {
      final file = await _getFile();
      if (!file.existsSync()) return;
      final value = file.readAsStringSync().trim();
      themeModeNotifier.value = switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {}
  }

  static Future<void> save(ThemeMode mode) async {
    try {
      final file = await _getFile();
      await file.writeAsString(switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      });
    } catch (_) {}
  }
}
