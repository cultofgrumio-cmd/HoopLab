import 'dart:ui';

import 'package:hooplab/models/clip.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/utils/make_detector.dart';

/// Emitted the moment a live shot is scored.
class LiveShotEvent {
  final bool made;
  final int total;
  final int makes;
  final int misses;
  final int streak; // current consecutive makes

  const LiveShotEvent({
    required this.made,
    required this.total,
    required this.makes,
    required this.misses,
    required this.streak,
  });
}

/// Real-time (streaming) shot + make/miss detector for the live workout mode.
///
/// It is fed one frame of detections at a time and returns a [LiveShotEvent]
/// exactly on the frame a shot is finalised (otherwise null). A shot is scored
/// when the ball, having approached from far, passes through the rim region:
///
///  * **armed** when the ball is far from the rim (ready for a new attempt),
///  * **at-rim** once it enters the rim's vicinity,
///  * **finalised** when the ball leaves the rim region.
///
/// The **make/miss decision is delegated to [MakeDetector]** — the exact same
/// improved opening-box detection the offline viewer uses — so a live shot and
/// the same shot re-analysed from video score identically. To do that the
/// tracker buffers the detections of the current attempt (the approach → rim →
/// leave window) and, at finalisation, hands that window plus the smoothed rim
/// bounding box to [MakeDetector]. That detector considers the model `made`
/// label, the ball passing through the rim *opening* (crossing or
/// point-in-opening), and a net-occlusion swish — none of which the old
/// distance-to-centre heuristic could see.
///
/// A refractory period prevents a single rattling shot from counting twice.
class LiveShotTracker {
  final double approachFactor; // enter rim vicinity below this × rim width
  final double farFactor; // re-arm above this × rim width
  final double refractorySeconds;

  LiveShotTracker({
    this.approachFactor = 2.2,
    this.farFactor = 3.2,
    this.refractorySeconds = 1.2,
  });

  /// Real-time tracker tuned for the selected camera rig. Only *segmentation*
  /// (when an attempt is registered) is tuned per mode — the make/miss decision
  /// itself is the same improved [MakeDetector] logic for every mode. In
  /// **ground** mode the upward tilt foreshortens the vertical axis, so the ball
  /// enters the rim's pixel vicinity a little sooner and is re-armed a little
  /// later.
  factory LiveShotTracker.forMode(RecordingMode mode) => switch (mode) {
        RecordingMode.tripod => LiveShotTracker(
            approachFactor: 2.2,
            farFactor: 3.2,
            refractorySeconds: 1.2,
          ),
        RecordingMode.ground => LiveShotTracker(
            approachFactor: 2.5,
            farFactor: 3.4,
            refractorySeconds: 1.2,
          ),
      };

  Offset? _rimCenter;
  double _rimWidth = 60;
  BoundingBox? _rimBBox; // smoothed rim opening, for the shared make detector

  bool _armed = false;
  bool _atRim = false;
  double _lastShotTime = -1000;

  // Detections buffered for the current attempt (approach → rim → leave), fed to
  // [MakeDetector] at finalisation so live scoring matches the offline pipeline.
  final List<FrameData> _window = [];
  static const int _maxWindowFrames = 120;

  int total = 0;
  int makes = 0;
  int misses = 0;
  int streak = 0;

  void reset() {
    _rimCenter = null;
    _rimBBox = null;
    _armed = false;
    _atRim = false;
    _lastShotTime = -1000;
    _window.clear();
    total = 0;
    makes = 0;
    misses = 0;
    streak = 0;
  }

  /// Feed one frame. Returns a [LiveShotEvent] on the frame a shot is scored.
  LiveShotEvent? onDetections(List<Detection> detections, double timeSeconds) {
    // Update the rim (exponential smoothing keeps it stable frame-to-frame).
    // The whole bounding box is smoothed — not just the centre — because the
    // shared make detector needs the rim *opening* to test whether the ball
    // passed through it.
    final rim = detections.where((d) => d.isRim).fold<Detection?>(
      null,
      (best, d) => best == null || d.confidence > best.confidence ? d : best,
    );
    if (rim != null) {
      if (_rimBBox == null) {
        _rimBBox = BoundingBox(
          x1: rim.bbox.x1,
          y1: rim.bbox.y1,
          x2: rim.bbox.x2,
          y2: rim.bbox.y2,
        );
      } else {
        final b = _rimBBox!;
        _rimBBox = BoundingBox(
          x1: b.x1 * 0.7 + rim.bbox.x1 * 0.3,
          y1: b.y1 * 0.7 + rim.bbox.y1 * 0.3,
          x2: b.x2 * 0.7 + rim.bbox.x2 * 0.3,
          y2: b.y2 * 0.7 + rim.bbox.y2 * 0.3,
        );
      }
      _rimCenter = _rimBBox!.toRect().center;
      _rimWidth = _rimBBox!.width.abs().clamp(10.0, 100000.0);
    }
    final rimCenter = _rimCenter;
    final rimBBox = _rimBBox;
    if (rimCenter == null || rimBBox == null) return null;

    final ball = detections.where((d) => d.isBall).fold<Detection?>(
      null,
      (best, d) => best == null || d.confidence > best.confidence ? d : best,
    );
    if (ball == null) return null;

    final distNorm = (ball.center - rimCenter).distance / _rimWidth;

    // Re-arm when the ball is clearly away from the rim, and start a fresh
    // window for the next attempt.
    if (distNorm > farFactor) {
      _armed = true;
      if (!_atRim) _window.clear();
    }

    // Buffer the approach/rim-zone frames (everything not clearly "far") so the
    // make detector sees the full arc through the rim.
    if (_armed && distNorm <= farFactor) {
      _window.add(FrameData(
        frameNumber: _window.length,
        timestamp: timeSeconds,
        detections: detections,
      ));
      if (_window.length > _maxWindowFrames) _window.removeAt(0);
    }

    if (_armed && !_atRim && distNorm < approachFactor) {
      _atRim = true;
    }

    if (_atRim) {
      // Finalise once the ball leaves the rim zone. Symmetric to how it entered,
      // so it works whether the ball drops onto the rim (overhead) or rises up
      // through it (front view).
      final leftRim = distNorm > approachFactor * 1.3;
      if (leftRim && (timeSeconds - _lastShotTime) > refractorySeconds) {
        final made = _scoreWindow(rimCenter, rimBBox);
        total++;
        if (made) {
          makes++;
          streak++;
        } else {
          misses++;
          streak = 0;
        }
        _lastShotTime = timeSeconds;
        _atRim = false;
        _armed = false;
        _window.clear();
        return LiveShotEvent(
          made: made,
          total: total,
          makes: makes,
          misses: misses,
          streak: streak,
        );
      }
    }
    return null;
  }

  /// Run the shared [MakeDetector] over the buffered attempt window.
  bool _scoreWindow(Offset rimCenter, BoundingBox rimBBox) {
    final ballPoints = <Offset>[];
    for (final f in _window) {
      final b = f.detections.where((d) => d.isBall).firstOrNull;
      if (b != null) ballPoints.add(b.center);
    }
    final result = MakeDetector.detect(
      frames: _window,
      ballPoints: ballPoints,
      rimCenter: rimCenter,
      rimBBox: rimBBox,
      rimRadius: _rimWidth / 2,
    );
    return result.made;
  }
}
