import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/services/audio_feedback.dart';
import 'package:hooplab/services/recording_mode_storage.dart';
import 'package:hooplab/utils/live_shot_tracker.dart';
import 'package:hooplab/widgets/recording_angle_guide.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Live workout: points the camera at the hoop and scores every shot in real
/// time, counting makes / misses / streak / total with optional spoken cues.
class LiveWorkoutPage extends StatefulWidget {
  const LiveWorkoutPage({super.key});

  @override
  State<LiveWorkoutPage> createState() => _LiveWorkoutPageState();
}

class _LiveWorkoutPageState extends State<LiveWorkoutPage> {
  final YOLOViewController _yoloController = YOLOViewController();
  // Tuned to the camera rig selected in Settings (tripod vs on-the-ground).
  final LiveShotTracker _tracker =
      LiveShotTracker.forMode(recordingModeNotifier.value);
  final AudioFeedback _audio = AudioFeedback();
  final Stopwatch _clock = Stopwatch()..start();

  // Live counters
  int _total = 0, _makes = 0, _misses = 0, _streak = 0, _bestStreak = 0;

  // Brief center flash after each scored shot
  bool? _lastMade;
  Timer? _flashTimer;

  // One-time positioning hint (the single supported recording angle).
  bool _showAngleHint = true;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _audio.init();
    LiveFeedbackPrefs.load();
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _audio.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  void _onResult(List<YOLOResult> results) {
    if (!mounted) return;
    final detections = [
      for (final r in results)
        Detection(
          trackId: 0,
          bbox: BoundingBox(
            x1: r.boundingBox.left,
            y1: r.boundingBox.top,
            x2: r.boundingBox.right,
            y2: r.boundingBox.bottom,
          ),
          confidence: r.confidence,
          timestamp: 0,
          label: r.className,
        ),
    ];

    final event = _tracker.onDetections(
      detections,
      _clock.elapsedMilliseconds / 1000.0,
    );
    if (event == null) return;

    setState(() {
      _total = event.total;
      _makes = event.makes;
      _misses = event.misses;
      _streak = event.streak;
      if (_streak > _bestStreak) _bestStreak = _streak;
      _lastMade = event.made;
    });

    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _lastMade = null);
    });

    if (LiveFeedbackPrefs.audioOn.value) {
      final phrase = liveAnnouncement(event, LiveFeedbackPrefs.enabled.value);
      if (phrase != null) _audio.speak(phrase);
    }
  }

  void _reset() {
    _tracker.reset();
    setState(() {
      _total = 0;
      _makes = 0;
      _misses = 0;
      _streak = 0;
      _bestStreak = 0;
      _lastMade = null;
    });
  }

  void _openFeedbackSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => const _FeedbackSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final makePct = _total > 0 ? (_makes / _total * 100) : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Live camera + on-device detection.
          YOLOView(
            modelPath: 'best_float16',
            task: YOLOTask.detect,
            controller: _yoloController,
            onResult: _onResult,
          ),

          // Center make/miss flash.
          if (_lastMade != null)
            Center(
              child: AnimatedOpacity(
                opacity: 1,
                duration: const Duration(milliseconds: 120),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 36, vertical: 20),
                  decoration: BoxDecoration(
                    color: (_lastMade! ? Colors.green : Colors.red)
                        .withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _lastMade! ? 'MAKE' : 'MISS',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
            ),

          // Top bar.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  const Text(
                    'Live Workout',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<bool>(
                    valueListenable: LiveFeedbackPrefs.audioOn,
                    builder: (_, on, __) => IconButton(
                      icon: Icon(
                        on ? Icons.volume_up : Icons.volume_off,
                        color: Colors.white,
                      ),
                      onPressed: () => LiveFeedbackPrefs.setAudioOn(!on),
                      tooltip: on ? 'Mute audio' : 'Unmute audio',
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.tune, color: Colors.white),
                    onPressed: _openFeedbackSettings,
                    tooltip: 'Audio feedback options',
                  ),
                ],
              ),
            ),
          ),

          // Positioning hint: the single supported recording angle. Dismissible
          // so it never permanently covers the live view.
          if (_showAngleHint)
            Align(
              alignment: Alignment.topCenter,
              child: SafeArea(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 56, 16, 0),
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 14),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Stand at the half-court / sideline corner',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close,
                                color: Colors.white70, size: 20),
                            onPressed: () =>
                                setState(() => _showAngleHint = false),
                            tooltip: 'Dismiss',
                          ),
                        ],
                      ),
                      const SizedBox(
                        width: 180,
                        child: RecordingAngleGuide(
                          onDark: true,
                          showCaption: false,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<RecordingMode>(
                        valueListenable: recordingModeNotifier,
                        builder: (_, mode, __) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.videocam_outlined,
                                color: Colors.orangeAccent, size: 16),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '${mode.shortLabel} mode · ${mode.setupTip}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Bottom stat panel.
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 18),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _Stat(label: 'Makes', value: '$_makes', color: Colors.green),
                        _Stat(label: 'Misses', value: '$_misses', color: Colors.red),
                        _Stat(
                          label: 'Streak',
                          value: '$_streak',
                          color: Colors.orange,
                        ),
                        _Stat(label: 'Total', value: '$_total'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${makePct.toStringAsFixed(0)}%  ·  best streak $_bestStreak',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 16),
                        TextButton.icon(
                          onPressed: _reset,
                          icon: const Icon(Icons.refresh, color: Colors.white),
                          label: const Text('Reset',
                              style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _Stat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ],
    );
  }
}

class _FeedbackSettingsSheet extends StatelessWidget {
  const _FeedbackSettingsSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Spoken feedback',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose what gets called out after each shot.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<Set<LiveFeedbackType>>(
              valueListenable: LiveFeedbackPrefs.enabled,
              builder: (_, enabled, __) => Column(
                children: [
                  for (final type in LiveFeedbackType.values)
                    SwitchListTile(
                      title: Text(type.label),
                      value: enabled.contains(type),
                      onChanged: (v) => LiveFeedbackPrefs.toggle(type, v),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
