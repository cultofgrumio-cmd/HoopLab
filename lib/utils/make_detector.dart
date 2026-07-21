import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/utils/trajectory_prediction.dart';

/// Tunable constants for [MakeDetector]. These are **camera-independent**: make
/// detection is deliberately the same across recording rigs (tripod / ground)
/// and across the live + offline pipelines, so "did the ball go in" is decided
/// one way everywhere. The values are exposed as a config only to keep the
/// magic numbers named and in one place.
class MakeDetectorConfig {
  /// Slack on the rim's X-span (as a fraction of its half-width) when testing
  /// whether the ball passed through the opening — accounts for the ball's own
  /// radius plus detection noise.
  final double edgeTolFactor;

  /// Max frame gap between the ball being seen above the rim and below it for a
  /// net-occlusion swish to count as a make.
  final int occlusionWindowFrames;

  const MakeDetectorConfig({
    this.edgeTolFactor = 0.15,
    this.occlusionWindowFrames = 12,
  });
}

/// Result of make/miss determination, with which signal decided it.
class MakeResult {
  final bool made;
  final double accuracy; // 0-100
  final ShotConfidence confidence;
  final String method;

  const MakeResult({
    required this.made,
    required this.accuracy,
    required this.confidence,
    required this.method,
  });
}

/// Determines whether a shot went in using **several independent signals**,
/// because no single geometric test is reliable across camera angles and YOLO
/// frequently loses the ball inside the net.
///
/// Signals, in priority order:
///  1. The model's `made` label near the rim (direct visual evidence).
///  2. The ball passing **through the rim opening**, detected two ways on the
///     densified trajectory:
///       a. a crossing of the rim's horizontal centre line whose interpolated
///          X lands within the rim's actual X-span (catches descending shots,
///          including off-centre / edge makes), and
///       b. any tracked point landing inside the rim's opening box (catches
///          sideways/court passes and balls last seen inside the ring before
///          being lost in the net).
///  3. A **net-occlusion swish**: ball seen above the rim in its column, then
///     below it (or lost) within a short window.
///
/// Both geometric tests use the rim **bounding box** (the real opening) rather
/// than a circle around the centre, so a clean make that goes in near the edge
/// of the rim is no longer mistaken for a miss. The bias is deliberately toward
/// *detecting* makes, since the common failure was clean makes scored as misses.
class MakeDetector {
  static MakeResult detect({
    required List<FrameData> frames,
    required List<Offset> ballPoints,
    required Offset rimCenter,
    BoundingBox? rimBBox,
    double rimRadius = 30,
    MakeDetectorConfig config = const MakeDetectorConfig(),
  }) {
    final radius =
        (rimBBox != null ? rimBBox.width / 2 : rimRadius).clamp(8.0, 100000.0);

    // 1) Model "made" label — strongest evidence.
    final made = TrajectoryPredictor.checkMadeDetection(
      frames,
      rimCenter,
      proximityThreshold: (radius * 4).clamp(120.0, 400.0),
    );
    if (made != null) {
      return MakeResult(
        made: true,
        accuracy: made.accuracy,
        confidence: ShotConfidence.high,
        method: 'made label',
      );
    }

    // 2) Ball passed through the rim opening (crossing or point-in-opening).
    final through = _throughRim(ballPoints, rimCenter, rimBBox, radius, config);
    if (through.made) return through;

    // 3) Net-occlusion swish.
    if (_occlusionSwish(frames, rimCenter, rimBBox, radius, config)) {
      return const MakeResult(
        made: true,
        accuracy: 75,
        confidence: ShotConfidence.medium,
        method: 'net swish',
      );
    }

    // Miss — carry the through-rim accuracy so a near-make still reads high.
    return MakeResult(
      made: false,
      accuracy: through.accuracy,
      confidence: through.confidence,
      method: 'miss',
    );
  }

  /// Decide whether the ball physically went through the hoop, using the rim's
  /// real opening (its bounding box) rather than a circle around the centre.
  ///
  /// Two complementary tests run on the densified trajectory:
  ///  * **Rim-plane crossing** — a segment straddles the rim's horizontal
  ///    centre line; the interpolated X at that height must fall inside the rim
  ///    X-span. Handles descending front-on shots, including off-centre/edge
  ///    makes where the ball never passes near the geometric centre.
  ///  * **Point-in-opening** — any (interpolated) point lands inside the rim
  ///    box. Handles sideways/court passes (no clean Y crossing) and balls last
  ///    seen inside the ring right before disappearing into the net.
  ///
  /// A small tolerance on the X-span accounts for the ball's own radius so a
  /// make that clips the very edge of the rim still counts.
  static MakeResult _throughRim(
    List<Offset> ballPoints,
    Offset rimCenter,
    BoundingBox? rimBBox,
    double radius,
    MakeDetectorConfig config,
  ) {
    if (ballPoints.length < 2) {
      return const MakeResult(
        made: false,
        accuracy: 0,
        confidence: ShotConfidence.insufficient,
        method: 'through opening',
      );
    }

    final left = rimBBox?.x1 ?? (rimCenter.dx - radius);
    final right = rimBBox?.x2 ?? (rimCenter.dx + radius);
    final top = rimBBox?.y1 ?? (rimCenter.dy - radius * 0.5);
    final bottom = rimBBox?.y2 ?? (rimCenter.dy + radius * 0.5);
    final centerX = (left + right) / 2;
    final halfSpan = ((right - left) / 2).clamp(1.0, 100000.0);
    final lineY = rimCenter.dy; // measure the crossing at the ring's height
    final tol = halfSpan * config.edgeTolFactor; // ball-radius + perspective slack

    final dense = _densify(ballPoints, 6);

    // (a) Crossing of the rim centre line, inside the X-span.
    double? crossX;
    for (int i = 1; i < dense.length; i++) {
      final a = dense[i - 1];
      final b = dense[i];
      final dy = b.dy - a.dy;
      if (dy.abs() < 1e-6) continue; // horizontal segment — handled by (b)
      final straddles =
          (a.dy <= lineY && b.dy >= lineY) || (a.dy >= lineY && b.dy <= lineY);
      if (!straddles) continue;
      final t = (lineY - a.dy) / dy;
      final x = a.dx + (b.dx - a.dx) * t;
      if (x >= left - tol && x <= right + tol) {
        if (crossX == null || (x - centerX).abs() < (crossX - centerX).abs()) {
          crossX = x;
        }
      }
    }

    // (b) A point inside the rim opening box.
    double? insideX;
    double insideBest = double.infinity;
    for (final p in dense) {
      if (p.dx >= left - tol &&
          p.dx <= right + tol &&
          p.dy >= top &&
          p.dy <= bottom) {
        final d = (p.dx - centerX).abs();
        if (d < insideBest) {
          insideBest = d;
          insideX = p.dx;
        }
      }
    }

    final throughX = crossX ?? insideX;
    if (throughX != null) {
      final centered = (1 - (throughX - centerX).abs() / halfSpan).clamp(0.0, 1.0);
      // Makes read 50–100%: an edge make is a make, just not a clean one.
      final accuracy = 50 + centered * 50;
      debugPrint(
        '🎯 Through-rim make: x=${throughX.toStringAsFixed(1)} '
        '(span ${left.toStringAsFixed(0)}–${right.toStringAsFixed(0)}, '
        'via ${crossX != null ? "crossing" : "opening"})',
      );
      return MakeResult(
        made: true,
        accuracy: accuracy,
        confidence: crossX != null ? ShotConfidence.high : ShotConfidence.medium,
        method: crossX != null ? 'rim crossing' : 'through opening',
      );
    }

    // No through-evidence: report closest approach as the (miss) accuracy so a
    // near-make still reads higher than an airball.
    double minDist = double.infinity;
    for (final p in dense) {
      final d = (p - rimCenter).distance;
      if (d < minDist) minDist = d;
    }
    final accuracy = ((1 - minDist / (radius * 2)) * 100).clamp(0.0, 100.0);
    return MakeResult(
      made: false,
      accuracy: accuracy,
      confidence: minDist < radius * 2
          ? ShotConfidence.low
          : ShotConfidence.insufficient,
      method: 'through opening',
    );
  }

  /// A swish often hides the ball in the net for a few frames. Detect: ball
  /// above the rim near its column → a short gap → ball below the rim near the
  /// same column.
  static bool _occlusionSwish(
    List<FrameData> frames,
    Offset rimCenter,
    BoundingBox? rimBBox,
    double radius,
    MakeDetectorConfig config,
  ) {
    final rimTop = rimBBox?.y1 ?? (rimCenter.dy - radius);
    final rimBottom = rimBBox?.y2 ?? (rimCenter.dy + radius);
    final colLeft = (rimBBox?.x1 ?? (rimCenter.dx - radius)) - radius;
    final colRight = (rimBBox?.x2 ?? (rimCenter.dx + radius)) + radius;

    bool inColumn(Offset p) => p.dx >= colLeft && p.dx <= colRight;

    int? aboveIdx;
    for (int i = 0; i < frames.length; i++) {
      final ball = frames[i].detections.where((d) => d.isBall).firstOrNull;
      if (ball == null) continue;
      final p = ball.center;
      if (!inColumn(p)) {
        // Ball wandered out of the rim column — reset the "above" anchor.
        if (aboveIdx != null && (p.dy < rimTop || p.dy > rimBottom)) {
          aboveIdx = null;
        }
        continue;
      }
      if (p.dy < rimTop) {
        aboveIdx = i;
      } else if (p.dy > rimBottom && aboveIdx != null) {
        // Found below-rim after an above-rim, within a reasonable window.
        if (i - aboveIdx <= config.occlusionWindowFrames) {
          debugPrint('🕸️ Net-occlusion swish detected (frames $aboveIdx→$i)');
          return true;
        }
        aboveIdx = null;
      }
    }
    return false;
  }

  static List<Offset> _densify(List<Offset> pts, int subdivisions) {
    if (pts.length < 2 || subdivisions < 1) return List.of(pts);
    final out = <Offset>[];
    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      for (int s = 0; s < subdivisions; s++) {
        out.add(Offset.lerp(a, b, s / subdivisions)!);
      }
    }
    out.add(pts.last);
    return out;
  }
}
