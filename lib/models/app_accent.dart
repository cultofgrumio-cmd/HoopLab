import 'package:flutter/material.dart';

/// A selectable accent / colour theme for the app. Each accent drives the
/// primary colour plus the tinted light and dark backgrounds, while keeping the
/// overall HoopLab layout and contrast the same. The default, [AppAccent.blue],
/// reproduces the original blue palette.
enum AppAccent { blue, teal, green, orange, red, purple }

extension AppAccentInfo on AppAccent {
  /// Display name shown next to the swatch in Settings.
  String get label => switch (this) {
        AppAccent.blue => 'Court Blue',
        AppAccent.teal => 'Teal',
        AppAccent.green => 'Court Green',
        AppAccent.orange => 'Sunset Orange',
        AppAccent.red => 'Hoop Red',
        AppAccent.purple => 'Purple',
      };

  /// Material colour swatch the light/dark themes are derived from.
  MaterialColor get swatch => switch (this) {
        AppAccent.blue => Colors.blue,
        AppAccent.teal => Colors.teal,
        AppAccent.green => Colors.green,
        AppAccent.orange => Colors.deepOrange,
        AppAccent.red => Colors.red,
        AppAccent.purple => Colors.purple,
      };

  /// A representative colour for the picker chip (readable on both light and
  /// dark surfaces).
  Color get sample => swatch.shade500;

  /// Stable key used for persistence.
  String get storageKey => name;

  /// Parse a persisted [storageKey] back to an accent, defaulting to [blue].
  static AppAccent fromStorageKey(String key) {
    final trimmed = key.trim();
    for (final accent in AppAccent.values) {
      if (accent.name == trimmed) return accent;
    }
    return AppAccent.blue;
  }
}
