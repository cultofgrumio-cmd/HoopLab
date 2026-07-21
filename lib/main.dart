import 'package:flutter/material.dart';

import 'package:hooplab/pages/method_selector.dart';
import 'package:hooplab/services/audio_feedback.dart';
import 'package:hooplab/services/recording_mode_storage.dart';
import 'package:hooplab/services/theme_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeStorage.load();
  await LiveFeedbackPrefs.load();
  await RecordingModeStorage.load();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          home: const MethodSelector(),
        );
      },
    );
  }
}

final ThemeData _lightTheme = ThemeData(
  brightness: Brightness.light,
  primaryColor: const Color(0xFF1565C0),
  scaffoldBackgroundColor: const Color(0xFFE3F2FD),
  colorScheme: const ColorScheme.light(
    primary: Color(0xFF1565C0),
    secondary: Color(0xFF0D47A1),
    surface: Color(0xFFFFFFFF),
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: Color(0xFF0D47A1),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF1565C0),
    foregroundColor: Colors.white,
    elevation: 0,
  ),
  cardTheme: const CardThemeData(
    color: Colors.white,
    elevation: 2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      side: BorderSide(color: Color(0x331565C0)),
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF1565C0),
      foregroundColor: Colors.white,
      elevation: 2,
    ),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Color(0xFF1565C0),
    foregroundColor: Colors.white,
  ),
);

final ThemeData _darkTheme = ThemeData(
  brightness: Brightness.dark,
  primaryColor: const Color(0xFF64B5F6),
  scaffoldBackgroundColor: const Color(0xFF0A1929),
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFF64B5F6),
    secondary: Color(0xFF1E88E5),
    surface: Color(0xFF102A43),
    onPrimary: Colors.black,
    onSecondary: Colors.white,
    onSurface: Color(0xFFE3F2FD),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF102A43),
    foregroundColor: Colors.white,
    elevation: 0,
  ),
  cardTheme: const CardThemeData(
    color: Color(0xFF102A43),
    elevation: 2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      side: BorderSide(color: Color(0x3364B5F6)),
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF1E88E5),
      foregroundColor: Colors.white,
      elevation: 2,
    ),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Color(0xFF1E88E5),
    foregroundColor: Colors.white,
  ),
);
