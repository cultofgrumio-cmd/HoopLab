import 'package:flutter/material.dart';

import 'package:hooplab/models/app_accent.dart';
import 'package:hooplab/pages/method_selector.dart';
import 'package:hooplab/services/audio_feedback.dart';
import 'package:hooplab/services/handedness_storage.dart';
import 'package:hooplab/services/recording_mode_storage.dart';
import 'package:hooplab/services/theme_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeStorage.load();
  await ThemeStorage.loadAccent();
  await LiveFeedbackPrefs.load();
  await RecordingModeStorage.load();
  await HandednessStorage.load();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<AppAccent>(
          valueListenable: themeAccentNotifier,
          builder: (context, accent, __) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              themeMode: mode,
              theme: _buildLightTheme(accent),
              darkTheme: _buildDarkTheme(accent),
              home: const MethodSelector(),
            );
          },
        );
      },
    );
  }
}

/// Builds the light theme for the given [accent].
///
/// Colours are derived from the accent's Material swatch so every palette keeps
/// the same relationships as the original blue design: an elevated primary, a
/// very light tinted background and a deep on-surface tone. With
/// [AppAccent.blue] this reproduces the original palette exactly.
ThemeData _buildLightTheme(AppAccent accent) {
  final swatch = accent.swatch;
  final primary = swatch.shade800;
  final secondary = swatch.shade900;
  final onSurface = swatch.shade900;
  final border = primary.withValues(alpha: 0.2);

  return ThemeData(
    brightness: Brightness.light,
    primaryColor: primary,
    scaffoldBackgroundColor: swatch.shade50,
    colorScheme: ColorScheme.light(
      primary: primary,
      secondary: secondary,
      surface: Colors.white,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: onSurface,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: primary,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: border),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: Colors.white,
    ),
  );
}

/// Builds the dark theme for the given [accent].
///
/// The primary/secondary come from lighter swatch shades so they read on dark
/// surfaces, while the scaffold and surface are dark, low-lightness tints of the
/// accent hue (matching the original near-black blue backgrounds).
ThemeData _buildDarkTheme(AppAccent accent) {
  final swatch = accent.swatch;
  final hue = HSLColor.fromColor(swatch).hue;
  final primary = swatch.shade300;
  final secondary = swatch.shade600;
  final scaffold = HSLColor.fromAHSL(1, hue, 0.58, 0.10).toColor();
  final surface = HSLColor.fromAHSL(1, hue, 0.55, 0.16).toColor();
  final border = primary.withValues(alpha: 0.2);

  return ThemeData(
    brightness: Brightness.dark,
    primaryColor: primary,
    scaffoldBackgroundColor: scaffold,
    colorScheme: ColorScheme.dark(
      primary: primary,
      secondary: secondary,
      surface: surface,
      onPrimary: Colors.black,
      onSecondary: Colors.white,
      onSurface: swatch.shade50,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: border),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: secondary,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: secondary,
      foregroundColor: Colors.white,
    ),
  );
}
