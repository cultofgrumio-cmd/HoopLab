import 'dart:math' as math;
import 'dart:ui';

import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/utils/trajectory_prediction.dart' show ShotConfidence;

/// Camera-geometry tuning for [ShotPredictor].
///
/// The predictor fits a projectile (gravity) parabola to the launch arc. In
/// **ground** mode the upward tilt foreshortens the vertical axis, so the
/// on-screen parabola is shallow and noisier — the fit error thresholds are
/// relaxed (so a prediction is still produced) but the confidence is capped
/// below `high`, since the geometry can't support a high-confidence call.
class ShotPredictorConfig {
  /// High-confidence fit RMSE ceiling, as a multiple of the rim radius.
  final double rmseHighFactor;

  /// Medium-confidence fit RMSE ceiling, as a multiple of the rim radius.
  final double rmseMediumFactor;

  /// Upper bound on the confidence this rig can produce.
  final ShotConfidence maxConfidence;

  const ShotPredictorConfig({
    this.rmseHighFactor = 1.0,
    this.rmseMediumFactor = 3.0,
    this.maxConfidence = ShotConfidence.high,
  });

  factory ShotPredictorConfig.forMode(RecordingMode mode) => switch (mode) {
        RecordingMode.tripod => const ShotPredictorConfig(),
        RecordingMode.ground => const ShotPredictorConfig(
            rmseHighFactor: 1.6,
            rmseMediumFactor: 4.0,
            maxConfidence: ShotConfidence.medium,
          ),
      };
}

/// The prediction made *at release* — from the launch portion of the shot only
/// (release → apex), before the outcome is visible. This lets the app tell the
/// shooter "that's going in / that's short" the moment the ball leaves the hand,
/// independently of whether it actually went in.
class ShotPrediction {
  final bool willMake;
  final double accuracy; // 0-100: how centred the projected path passes the rim
  final ShotConfidence confidence;

  /// The projected point of closest approach to the rim (image coords) — handy
  /// for drawing the predicted landing on the overlay. Null when unknown.
  final Offset? projectedPoint;

  const ShotPrediction({
    required this.willMake,
    required this.accuracy,
    required this.confidence,
    this.projectedPoint,
  });

  static const ShotPrediction unknown = ShotPrediction(
    willMake: false,
    accuracy: 0,
    confidence: ShotConfidence.insufficient,
    projectedPoint: null,
  );

  bool get isKnown => confidence != ShotConfidence.insufficient;
}

/// Predicts whether a shot will go in using only the early (launch) part of the
/// trajectory. It fits a projectile model — x linear in time, y quadratic
/// (gravity) — to the release→apex arc, then extrapolates the descent and
/// measures how close the projected path passes the rim centre.
class ShotPredictor {
  /// [ballPoints] and [timestamps] are the shot's ball track (parallel, ordered
  /// by time). Only the launch portion is used, so this never peeks at the
  /// actual outcome.
  static ShotPrediction predictFromRelease({
    required List<Offset> ballPoints,
    required List<double> timestamps,
    required Offset rimCenter,
    required double rimRadius,
    ShotPredictorConfig config = const ShotPredictorConfig(),
  }) {
    if (ballPoints.length < 3 || ballPoints.length != timestamps.length) {
      return ShotPrediction.unknown;
    }
    final radius = rimRadius <= 0 ? 30.0 : rimRadius;

    // ---- Isolate the launch arc: release → apex (highest point) ------------
    int apex = 0;
    for (int i = 1; i < ballPoints.length; i++) {
      if (ballPoints[i].dy < ballPoints[apex].dy) apex = i; // smaller y = higher
    }
    // Walk back from the apex while the ball was rising, to find the release.
    int start = apex;
    while (start > 0 && ballPoints[start - 1].dy >= ballPoints[start].dy - 2) {
      start--;
    }
    var end = apex;
    // Ensure at least 3 points to fit; extend forward if the ascent was tiny.
    if (end - start < 2) {
      end = (start + 2).clamp(0, ballPoints.length - 1);
    }
    if (end - start < 2) {
      return ShotPrediction.unknown;
    }

    final xs = <double>[];
    final ys = <double>[];
    final us = <double>[]; // time since release
    final t0 = timestamps[start];
    for (int i = start; i <= end; i++) {
      xs.add(ballPoints[i].dx);
      ys.add(ballPoints[i].dy);
      us.add(timestamps[i] - t0);
    }
    if (us.last - us.first <= 0) return ShotPrediction.unknown;

    final xFit = _fitLinear(us, xs);
    final yFit = _fitQuadratic(us, ys);
    if (xFit == null || yFit == null) return ShotPrediction.unknown;

    // ---- Project forward and find closest approach to the rim --------------
    final launchDuration = us.last;
    final uMax = launchDuration * 4.0;
    const steps = 120;
    double minDist = double.infinity;
    Offset? closest;
    for (int s = 0; s <= steps; s++) {
      final u = uMax * s / steps;
      final x = xFit.$1 * u + xFit.$2;
      final y = yFit.$1 * u * u + yFit.$2 * u + yFit.$3;
      final p = Offset(x, y);
      final d = (p - rimCenter).distance;
      if (d < minDist) {
        minDist = d;
        closest = p;
      }
    }

    // ---- Fit quality → confidence -----------------------------------------
    double sse = 0;
    for (int i = 0; i < us.length; i++) {
      final u = us[i];
      final yhat = yFit.$1 * u * u + yFit.$2 * u + yFit.$3;
      sse += (ys[i] - yhat) * (ys[i] - yhat);
    }
    final rmse = (sse / us.length) <= 0 ? 0.0 : math.sqrt(sse / us.length);
    final downwardArc = yFit.$1 > 0; // gravity should curve the path back down

    ShotConfidence confidence;
    if (us.length >= 5 && rmse < radius * config.rmseHighFactor && downwardArc) {
      confidence = ShotConfidence.high;
    } else if (downwardArc && rmse < radius * config.rmseMediumFactor) {
      confidence = ShotConfidence.medium;
    } else {
      confidence = ShotConfidence.low;
    }
    // A tilted-up rig can't support a high-confidence projectile fit.
    if (confidence.index < config.maxConfidence.index) {
      confidence = config.maxConfidence;
    }

    final accuracy = ((1 - (minDist / radius)) * 100).clamp(0.0, 100.0);
    return ShotPrediction(
      willMake: accuracy > 50.0,
      accuracy: accuracy,
      confidence: confidence,
      projectedPoint: closest,
    );
  }

  /// Least-squares y = a·u + b. Returns (a, b) or null if degenerate.
  static (double, double)? _fitLinear(List<double> u, List<double> y) {
    final n = u.length;
    double su = 0, sy = 0, suu = 0, suy = 0;
    for (int i = 0; i < n; i++) {
      su += u[i];
      sy += y[i];
      suu += u[i] * u[i];
      suy += u[i] * y[i];
    }
    final det = n * suu - su * su;
    if (det == 0) return null;
    final a = (n * suy - su * sy) / det;
    final b = (sy - a * su) / n;
    return (a, b);
  }

  /// Least-squares y = a·u² + b·u + c. Returns (a, b, c) or null if degenerate.
  static (double, double, double)? _fitQuadratic(List<double> u, List<double> y) {
    final n = u.length.toDouble();
    double s1 = 0, s2 = 0, s3 = 0, s4 = 0, sy = 0, suy = 0, suuy = 0;
    for (int i = 0; i < u.length; i++) {
      final ui = u[i];
      final u2 = ui * ui;
      s1 += ui;
      s2 += u2;
      s3 += u2 * ui;
      s4 += u2 * u2;
      sy += y[i];
      suy += ui * y[i];
      suuy += u2 * y[i];
    }
    // Normal equations:
    // [s4 s3 s2][a]   [suuy]
    // [s3 s2 s1][b] = [suy ]
    // [s2 s1 n ][c]   [sy  ]
    return _solve3(
      [
        [s4, s3, s2],
        [s3, s2, s1],
        [s2, s1, n],
      ],
      [suuy, suy, sy],
    );
  }

  /// Solve a 3×3 linear system by Gaussian elimination with partial pivoting.
  static (double, double, double)? _solve3(
    List<List<double>> a,
    List<double> b,
  ) {
    final m = [
      [a[0][0], a[0][1], a[0][2], b[0]],
      [a[1][0], a[1][1], a[1][2], b[1]],
      [a[2][0], a[2][1], a[2][2], b[2]],
    ];
    for (int col = 0; col < 3; col++) {
      int piv = col;
      for (int r = col + 1; r < 3; r++) {
        if (m[r][col].abs() > m[piv][col].abs()) piv = r;
      }
      if (m[piv][col].abs() < 1e-9) return null;
      final tmp = m[col];
      m[col] = m[piv];
      m[piv] = tmp;
      for (int r = 0; r < 3; r++) {
        if (r == col) continue;
        final factor = m[r][col] / m[col][col];
        for (int k = col; k < 4; k++) {
          m[r][k] -= factor * m[col][k];
        }
      }
    }
    return (m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2]);
  }
}
