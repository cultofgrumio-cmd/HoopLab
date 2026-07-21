import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hooplab/models/app_accent.dart';
import 'package:path_provider/path_provider.dart';

final themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

/// The selected colour theme. Drives the app's primary colour and tinted
/// backgrounds via the theme builders in `main.dart`.
final themeAccentNotifier = ValueNotifier<AppAccent>(AppAccent.blue);

class ThemeStorage {
  static const _fileName = 'theme_mode.txt';
  static const _accentFileName = 'theme_accent.txt';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<File> _accentFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_accentFileName');
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

  static Future<void> loadAccent() async {
    try {
      final file = await _accentFile();
      if (!file.existsSync()) return;
      final value = file.readAsStringSync().trim();
      themeAccentNotifier.value = AppAccentInfo.fromStorageKey(value);
    } catch (_) {}
  }

  static Future<void> saveAccent(AppAccent accent) async {
    try {
      final file = await _accentFile();
      await file.writeAsString(accent.storageKey);
    } catch (_) {}
  }

  /// Update the notifier and persist in one call.
  static void setAccent(AppAccent accent) {
    themeAccentNotifier.value = accent;
    saveAccent(accent);
  }
}
