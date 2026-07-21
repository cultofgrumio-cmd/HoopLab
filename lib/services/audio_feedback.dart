import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:hooplab/utils/live_shot_tracker.dart';
import 'package:path_provider/path_provider.dart';

/// The kinds of spoken feedback the user can toggle in live workout mode.
enum LiveFeedbackType { makeMiss, streak, total }

extension LiveFeedbackTypeLabel on LiveFeedbackType {
  String get label => switch (this) {
        LiveFeedbackType.makeMiss => 'Make / miss call',
        LiveFeedbackType.streak => 'Shots in a row',
        LiveFeedbackType.total => 'Total shots',
      };

  String get storageKey => switch (this) {
        LiveFeedbackType.makeMiss => 'makeMiss',
        LiveFeedbackType.streak => 'streak',
        LiveFeedbackType.total => 'total',
      };
}

/// Builds the phrase spoken for a shot event, honouring the enabled options.
/// Returns null when nothing should be spoken. Pure — unit-testable.
String? liveAnnouncement(LiveShotEvent e, Set<LiveFeedbackType> enabled) {
  final parts = <String>[];
  if (enabled.contains(LiveFeedbackType.makeMiss)) {
    parts.add(e.made ? 'Make' : 'Miss');
  }
  if (enabled.contains(LiveFeedbackType.streak) && e.made && e.streak >= 2) {
    parts.add('${e.streak} in a row');
  }
  if (enabled.contains(LiveFeedbackType.total)) {
    parts.add('${e.total} ${e.total == 1 ? "shot" : "shots"}');
  }
  return parts.isEmpty ? null : parts.join('. ');
}

/// Persisted live-workout audio preferences.
class LiveFeedbackPrefs {
  static const _fileName = 'live_feedback.txt';

  static final ValueNotifier<Set<LiveFeedbackType>> enabled =
      ValueNotifier<Set<LiveFeedbackType>>({LiveFeedbackType.makeMiss});
  static final ValueNotifier<bool> audioOn = ValueNotifier<bool>(true);

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return;
      final lines = file.readAsStringSync().trim().split('\n');
      final set = <LiveFeedbackType>{};
      for (final line in lines) {
        if (line == 'audioOff') {
          audioOn.value = false;
          continue;
        }
        for (final t in LiveFeedbackType.values) {
          if (t.storageKey == line.trim()) set.add(t);
        }
      }
      if (set.isNotEmpty) enabled.value = set;
    } catch (_) {}
  }

  static Future<void> save() async {
    try {
      final file = await _file();
      final lines = [
        for (final t in enabled.value) t.storageKey,
        if (!audioOn.value) 'audioOff',
      ];
      await file.writeAsString(lines.join('\n'));
    } catch (_) {}
  }

  static void toggle(LiveFeedbackType type, bool on) {
    final set = Set<LiveFeedbackType>.from(enabled.value);
    if (on) {
      set.add(type);
    } else {
      set.remove(type);
    }
    enabled.value = set;
    save();
  }

  static void setAudioOn(bool on) {
    audioOn.value = on;
    save();
  }
}

/// Thin wrapper around flutter_tts for short, non-overlapping spoken cues.
class AudioFeedback {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  Future<void> init() async {
    try {
      if (Platform.isIOS) {
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            IosTextToSpeechAudioCategoryOptions.duckOthers,
          ],
        );
      }
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      _ready = true;
    } catch (e) {
      debugPrint('TTS init failed: $e');
    }
  }

  Future<void> speak(String text) async {
    if (!_ready) return;
    try {
      // Interrupt any in-progress phrase so cues stay in sync with play.
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS speak failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
