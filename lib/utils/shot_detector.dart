import 'dart:ui';

import 'package:hooplab/models/clip.dart';
import 'package:hooplab/models/recording_mode.dart';

/// A detected shot span expressed as an inclusive range of frame indices into
/// the analyzed frame list, plus the rim the ball was heading toward.
class ShotWindow {
  final int startIndex;
  final int endIndex;
  final Offset? hoop;
  final BoundingBox? hoopBBox;

  const ShotWindow({
    required this.startIndex,
    required this.endIndex,
    this.hoop,
    this.hoopBBox,
  });

  int get length => endIndex - startIndex + 1;
}

/// Tunable thresholds for [ShotDetector]. Defaults are deliberately permissive;
/// the detector is designed to over-segment slightly and let downstream scoring
/// (rim-crossing / "made" label) sort out makes vs misses, rather than miss
/// real shots.
///
/// The defaults are tuned for HoopLab's single prescribed recording angle: the
/// player stands where the half-court line meets a sideline and aims across the
/// court at the rim. From that diagonal corner the ball passes *through* the rim
/// plane rather than dropping straight onto it, so proximity is kept slightly
/// looser and the trailing window a touch longer than a head-on backboard view
/// would need. There is only one angle, so there is only one configuration.
class ShotDetectorConfig {
  /// Ball is considered "at the rim" when its distance to the rim centre is
  /// below [approachFactor] × rim width.
  final double approachFactor;

  /// To count as a shot (rather than the ball merely sitting near the rim), the
  /// ball must have been at least [farFactor] × rim width away at some point in
  /// the lead-up window — i.e. it travelled toward the rim.
  final double farFactor;

  final double leadSeconds; // window captured before the ball reaches the rim
  final double trailSeconds; // window captured after (arc + landing)
  final double refractorySeconds; // min gap between distinct shots
  final int minShotFrames;
  final int minBallPoints;
  final int gapToleranceFrames; // ball-less frames tolerated inside an approach

  const ShotDetectorConfig({
    this.approachFactor = 2.4,
    this.farFactor = 3.0,
    this.leadSeconds = 1.0,
    this.trailSeconds = 0.75,
    this.refractorySeconds = 0.7,
    this.minShotFrames = 8,
    this.minBallPoints = 3,
    this.gapToleranceFrames = 8,
  });

  /// Preset tuned for the selected camera rig.
  ///
  /// * **Tripod** (level, elevated — the rim is seen close to edge-on): the ball
  ///   drops through and out of the rim quickly, so the approach can be tight and
  ///   the trailing window short.
  /// * **Ground** (tilted up — the vertical axis is foreshortened): the ball
  ///   approaches more head-on and lingers visually near the rim, and is more
  ///   often occluded by the rim/backboard, so the approach is looser, the trail
  ///   longer, and more ball-less frames are tolerated inside an approach.
  factory ShotDetectorConfig.forMode(RecordingMode mode) => switch (mode) {
        RecordingMode.tripod => const ShotDetectorConfig(
            approachFactor: 2.2,
            farFactor: 3.0,
            leadSeconds: 1.0,
            trailSeconds: 0.6,
            gapToleranceFrames: 8,
          ),
        RecordingMode.ground => const ShotDetectorConfig(
            approachFactor: 2.7,
            farFactor: 3.3,
            leadSeconds: 1.1,
            trailSeconds: 0.9,
            gapToleranceFrames: 12,
          ),
      };
}

class _Rim {
  Offset center;
  BoundingBox bbox;
  int count;
  _Rim(this.center, this.bbox, this.count);
}

class _BallSample {
  final int frame; // index into frames
  final Offset pos;
  const _BallSample(this.frame, this.pos);
}

/// Robust shot segmentation for HoopLab's single prescribed recording angle
/// (half-court/sideline corner, camera aimed across the court at the rim).
///
/// The backbone signal is the ball's trajectory toward a rim: a shot is a span
/// where the ball travels from far away and reaches the rim's vicinity. From the
/// diagonal corner view the ball passes through the rim plane, and the same
/// approach-based algorithm handles it with one tuned [ShotDetectorConfig].
///
/// Pose / YOLO `shoot` motion is used only to *rescue* shots the ball geometry
/// is unsure about (e.g. the ball was lost mid-arc), never as a hard gate — so
/// the detector still works on clips with no visible shooter. If no rim was
/// ever detected, it falls back to motion windows so it never silently returns
/// nothing when there is clearly a shot happening.
class ShotDetector {
  static List<ShotWindow> detect(
    List<FrameData> frames, {
    ShotDetectorConfig? config,
  }) {
    final cfg = config ?? const ShotDetectorConfig();
    if (frames.isEmpty) return const [];

    final rims = _clusterRims(frames);
    final dt = _medianDt(frames);
    final lead = (cfg.leadSeconds / dt).round().clamp(3, 240);
    final trail = (cfg.trailSeconds / dt).round().clamp(3, 240);

    // Primary path: detect approaches to each detected rim, then merge.
    final windows = <ShotWindow>[];
    for (final rim in rims) {
      windows.addAll(_detectApproachesToRim(frames, rim, cfg, lead, trail));
    }

    var merged = _mergeOverlapping(windows);
    merged = _enforceRefractory(merged, frames, cfg.refractorySeconds);
    merged = merged
        .where((w) =>
            w.length >= cfg.minShotFrames &&
            _ballCount(frames, w) >= cfg.minBallPoints)
        .toList();

    // Fail-proof fallbacks:
    // 1. Nothing from geometry but there IS shooting motion → motion windows.
    // 2. No rim ever detected → motion windows (unscored but still surfaced).
    if (merged.isEmpty) {
      final fallback = _motionWindows(frames, rims, cfg, lead, trail);
      if (fallback.isNotEmpty) return fallback;
    }

    return merged;
  }

  // ---- Rim clustering -------------------------------------------------------

  static List<_Rim> _clusterRims(List<FrameData> frames) {
    final rims = <_Rim>[];
    for (final f in frames) {
      for (final d in f.detections) {
        if (!d.isRim) continue;
        final c = d.center;
        _Rim? match;
        for (final r in rims) {
          final mergeDist = (r.bbox.width.abs().clamp(20.0, 400.0)) * 0.9;
          if ((r.center - c).distance < mergeDist) {
            match = r;
            break;
          }
        }
        if (match == null) {
          rims.add(_Rim(c, d.bbox, 1));
        } else {
          // Running average so the rim centre/size is stable across frames.
          final n = match.count + 1;
          match.center = Offset(
            (match.center.dx * match.count + c.dx) / n,
            (match.center.dy * match.count + c.dy) / n,
          );
          match.bbox = BoundingBox(
            x1: (match.bbox.x1 * match.count + d.bbox.x1) / n,
            y1: (match.bbox.y1 * match.count + d.bbox.y1) / n,
            x2: (match.bbox.x2 * match.count + d.bbox.x2) / n,
            y2: (match.bbox.y2 * match.count + d.bbox.y2) / n,
          );
          match.count = n;
        }
      }
    }
    // Ignore rims that appeared in only a couple of frames (spurious boxes),
    // unless that's all we have.
    if (rims.length > 1) {
      final maxCount = rims.fold<int>(0, (m, r) => r.count > m ? r.count : m);
      final threshold = (maxCount * 0.15).ceil();
      final strong = rims.where((r) => r.count >= threshold).toList();
      if (strong.isNotEmpty) return strong;
    }
    return rims;
  }

  // ---- Approach detection ---------------------------------------------------

  static List<ShotWindow> _detectApproachesToRim(
    List<FrameData> frames,
    _Rim rim,
    ShotDetectorConfig cfg,
    int lead,
    int trail,
  ) {
    final rimWidth = rim.bbox.width.abs().clamp(10.0, 100000.0);
    final samples = _ballSamples(frames);
    if (samples.length < 3) return const [];

    final d = <double>[
      for (final s in samples) (s.pos - rim.center).distance / rimWidth,
    ];

    // Contiguous runs of samples that are "at the rim", tolerating short gaps
    // where the ball detector dropped out.
    final windows = <ShotWindow>[];
    int i = 0;
    while (i < samples.length) {
      if (d[i] >= cfg.approachFactor) {
        i++;
        continue;
      }
      int j = i;
      while (j + 1 < samples.length &&
          d[j + 1] < cfg.approachFactor &&
          (samples[j + 1].frame - samples[j].frame) <= cfg.gapToleranceFrames) {
        j++;
      }

      // Apex = closest approach within the run.
      int apex = i;
      for (int k = i; k <= j; k++) {
        if (d[k] < d[apex]) apex = k;
      }
      final apexFrame = samples[apex].frame;
      final runStartFrame = samples[i].frame;
      final runEndFrame = samples[j].frame;

      // Did the ball travel from far away into the rim (a real shot), or was it
      // just loitering near the rim? Check the lead-up window.
      final leadFloor = apexFrame - lead;
      double maxDBefore = 0;
      for (int k = 0; k <= apex; k++) {
        if (samples[k].frame >= leadFloor && d[k] > maxDBefore) {
          maxDBefore = d[k];
        }
      }
      final hasApproach = maxDBefore >= cfg.farFactor;
      final hasMotion = _motionBetween(frames, leadFloor, apexFrame);

      if (hasApproach || hasMotion) {
        final start = (runStartFrame - lead).clamp(0, frames.length - 1);
        final end = (runEndFrame + trail).clamp(0, frames.length - 1);
        windows.add(ShotWindow(
          startIndex: start,
          endIndex: end,
          hoop: rim.center,
          hoopBBox: rim.bbox,
        ));
      }
      i = j + 1;
    }
    return windows;
  }

  // ---- Motion fallback ------------------------------------------------------

  static List<ShotWindow> _motionWindows(
    List<FrameData> frames,
    List<_Rim> rims,
    ShotDetectorConfig cfg,
    int lead,
    int trail,
  ) {
    final windows = <ShotWindow>[];
    int i = 0;
    while (i < frames.length) {
      if (!frames[i].isShootingMotion) {
        i++;
        continue;
      }
      int j = i;
      while (j + 1 < frames.length && frames[j + 1].isShootingMotion) {
        j++;
      }
      final start = (i - (lead ~/ 2)).clamp(0, frames.length - 1);
      final end = (j + trail).clamp(0, frames.length - 1);
      // Attach the rim the ball ends up nearest to (best effort).
      final rim = _nearestRimToWindow(frames, start, end, rims);
      windows.add(ShotWindow(
        startIndex: start,
        endIndex: end,
        hoop: rim?.center,
        hoopBBox: rim?.bbox,
      ));
      i = j + 1;
    }

    final merged = _mergeOverlapping(windows);
    return merged
        .where((w) =>
            w.length >= cfg.minShotFrames &&
            _ballCount(frames, w) >= cfg.minBallPoints)
        .toList();
  }

  static _Rim? _nearestRimToWindow(
    List<FrameData> frames,
    int start,
    int end,
    List<_Rim> rims,
  ) {
    if (rims.isEmpty) return null;
    if (rims.length == 1) return rims.first;
    // Use the ball's last known position in the window as the anchor.
    Offset? lastBall;
    for (int k = start; k <= end && k < frames.length; k++) {
      final b = frames[k].detections.where((x) => x.isBall).firstOrNull;
      if (b != null) lastBall = b.center;
    }
    if (lastBall == null) {
      return rims.reduce((a, b) => a.count >= b.count ? a : b);
    }
    final anchor = lastBall;
    return rims.reduce(
      (a, b) => (a.center - anchor).distance <= (b.center - anchor).distance
          ? a
          : b,
    );
  }

  // ---- Helpers --------------------------------------------------------------

  static List<_BallSample> _ballSamples(List<FrameData> frames) {
    final out = <_BallSample>[];
    for (int idx = 0; idx < frames.length; idx++) {
      final b = frames[idx].detections.where((d) => d.isBall).firstOrNull;
      if (b != null) out.add(_BallSample(idx, b.center));
    }
    return out;
  }

  static bool _motionBetween(List<FrameData> frames, int fromFrame, int toFrame) {
    final lo = fromFrame.clamp(0, frames.length - 1);
    final hi = toFrame.clamp(0, frames.length - 1);
    for (int k = lo; k <= hi; k++) {
      if (frames[k].isShootingMotion) return true;
    }
    return false;
  }

  static int _ballCount(List<FrameData> frames, ShotWindow w) {
    int n = 0;
    for (int k = w.startIndex; k <= w.endIndex && k < frames.length; k++) {
      if (frames[k].detections.any((d) => d.isBall)) n++;
    }
    return n;
  }

  static double _medianDt(List<FrameData> frames) {
    if (frames.length < 2) return 1 / 30.0;
    final diffs = <double>[];
    for (int i = 1; i < frames.length; i++) {
      final dt = frames[i].timestamp - frames[i - 1].timestamp;
      if (dt > 0) diffs.add(dt);
    }
    if (diffs.isEmpty) return 1 / 30.0;
    diffs.sort();
    final mid = diffs[diffs.length ~/ 2];
    return mid > 0 ? mid : 1 / 30.0;
  }

  static List<ShotWindow> _mergeOverlapping(List<ShotWindow> windows) {
    if (windows.length < 2) return List.of(windows);
    final sorted = List.of(windows)
      ..sort((a, b) => a.startIndex.compareTo(b.startIndex));
    final out = <ShotWindow>[sorted.first];
    for (int i = 1; i < sorted.length; i++) {
      final w = sorted[i];
      final last = out.last;
      if (w.startIndex <= last.endIndex) {
        out[out.length - 1] = ShotWindow(
          startIndex: last.startIndex,
          endIndex: w.endIndex > last.endIndex ? w.endIndex : last.endIndex,
          hoop: last.hoop ?? w.hoop,
          hoopBBox: last.hoopBBox ?? w.hoopBBox,
        );
      } else {
        out.add(w);
      }
    }
    return out;
  }

  static List<ShotWindow> _enforceRefractory(
    List<ShotWindow> windows,
    List<FrameData> frames,
    double refractorySeconds,
  ) {
    if (windows.length < 2) return List.of(windows);
    final sorted = List.of(windows)
      ..sort((a, b) => a.startIndex.compareTo(b.startIndex));
    final out = <ShotWindow>[sorted.first];
    for (int i = 1; i < sorted.length; i++) {
      final w = sorted[i];
      final last = out.last;
      final gap = frames[w.startIndex.clamp(0, frames.length - 1)].timestamp -
          frames[last.endIndex.clamp(0, frames.length - 1)].timestamp;
      if (gap < refractorySeconds) {
        // Same shot rattling around the rim — merge.
        out[out.length - 1] = ShotWindow(
          startIndex: last.startIndex,
          endIndex: w.endIndex > last.endIndex ? w.endIndex : last.endIndex,
          hoop: last.hoop ?? w.hoop,
          hoopBBox: last.hoopBBox ?? w.hoopBBox,
        );
      } else {
        out.add(w);
      }
    }
    return out;
  }
}
