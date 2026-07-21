import 'dart:math';
import 'package:flutter/material.dart';
import 'package:hooplab/models/clip.dart';

class TrajectoryPredictor {
  /// Predict trajectory using linear regression (similar to the GitHub repo approach)
  static List<Offset> predictTrajectory({
    required List<Offset> ballPoints,
    required Offset? hoopPosition,
    int predictionSteps = 20,
  }) {
    if (ballPoints.length < 3) return [];

    // Use the last few points for prediction (more recent = more accurate)
    final recentPoints = ballPoints.length > 5
        ? ballPoints.sublist(ballPoints.length - 5)
        : ballPoints;

    if (recentPoints.length < 2) return [];

    // Perform linear regression on X and Y separately
    final xRegression = _performLinearRegression(recentPoints, true);
    final yRegression = _performLinearRegression(recentPoints, false);

    if (xRegression == null || yRegression == null) return [];

    // Generate predicted points
    List<Offset> predictedPoints = [];
    final lastTimestamp = recentPoints.length.toDouble();

    for (int i = 1; i <= predictionSteps; i++) {
      final futureTime = lastTimestamp + i;

      final predictedX = xRegression.slope * futureTime + xRegression.intercept;
      final predictedY = yRegression.slope * futureTime + yRegression.intercept;

      predictedPoints.add(Offset(predictedX, predictedY));

      // If we have a hoop position, stop prediction near the hoop
      if (hoopPosition != null) {
        final distanceToHoop =
            (Offset(predictedX, predictedY) - hoopPosition).distance;
        if (distanceToHoop < 50) break; // Stop within 50 pixels of hoop
      }
    }

    return predictedPoints;
  }

  /// Predict corrected arc trajectory for missed shots
  /// Returns the arc that would have made the shot go in
  static List<Offset> predictCorrectedArc({
    required List<Offset> ballPoints,
    required Offset hoopPosition,
    int predictionSteps = 30,
  }) {
    if (ballPoints.length < 3) return [];

    // Use the first few points to determine initial trajectory
    final startPoints = ballPoints.length > 5
        ? ballPoints.sublist(0, 5)
        : ballPoints;

    if (startPoints.length < 2) return [];

    // Get the starting point of the trajectory
    final startPoint = startPoints.first;

    // Calculate the arc that would reach the hoop center
    final dx = hoopPosition.dx - startPoint.dx;
    final dy = hoopPosition.dy - startPoint.dy;

    List<Offset> correctedArc = [];

    // Create a parabolic arc from start to hoop
    for (int i = 0; i <= predictionSteps; i++) {
      final t = i / predictionSteps;

      // Parabolic interpolation
      // x follows linear path
      final x = startPoint.dx + dx * t;

      // y follows parabolic path with peak in the middle
      final peakHeight =
          min(startPoint.dy, hoopPosition.dy) - 100; // Arc 100px above
      final y =
          startPoint.dy +
          dy * t +
          4 * (peakHeight - startPoint.dy) * t * (1 - t);

      correctedArc.add(Offset(x, y));
    }

    return correctedArc;
  }

  /// Check if predicted trajectory intersects with hoop (shot success detection)
  /// Check if shot will go in using rim-crossing detection
  /// Uses linear interpolation between last point above rim and first point below rim
  static bool willShotGoIn({
    required List<Offset> ballPoints,
    required Offset hoopPosition,
    double hoopRadius = 30.0,
  }) {
    // Work on a copy — the caller reuses [ballPoints] for trajectory
    // prediction, so mutating it here would corrupt those results.
    final points = _densify(ballPoints);
    if (points.length < 3) return false;
    return _rimCrossingIsMake(points, hoopPosition, hoopRadius);
  }

  /// Insert interpolated midpoints to raise trajectory resolution without
  /// smoothing the real arc. Returns a new list; the input is never mutated.
  static List<Offset> _densify(List<Offset> ballPoints) {
    final points = <Offset>[];
    for (int i = 0; i < ballPoints.length; i++) {
      if (i > 0) {
        final inBetween = Offset.lerp(ballPoints[i - 1], ballPoints[i], 0.5)!;
        points.add(Offset.lerp(ballPoints[i - 1], inBetween, 0.5)!);
      }
      points.add(ballPoints[i]);
    }
    return points;
  }

  static bool _rimCrossingIsMake(
    List<Offset> ballPoints,
    Offset hoopPosition,
    double hoopRadius,
  ) {

    // Calculate rim height (top of hoop)
    final rimHeight = hoopPosition.dy - (hoopRadius * 0.5);

    // Find crossing points: last point above rim, first point below rim
    Offset? pointAboveRim;
    Offset? pointBelowRim;

    // Search backwards through trajectory
    for (int i = ballPoints.length - 1; i >= 0; i--) {
      if (ballPoints[i].dy < rimHeight && pointAboveRim == null) {
        pointAboveRim = ballPoints[i];
        // Get the next point (which should be below)
        if (i + 1 < ballPoints.length) {
          pointBelowRim = ballPoints[i + 1];
        }
        break;
      }
    }

    if (pointAboveRim == null || pointBelowRim == null) {
      debugPrint('❌ No rim crossing detected');
      return false;
    }

    // Linear interpolation to find X coordinate at rim height
    // Formula: x = x1 + (x2 - x1) * (rimHeight - y1) / (y2 - y1)
    final x1 = pointAboveRim.dx;
    final y1 = pointAboveRim.dy;
    final x2 = pointBelowRim.dx;
    final y2 = pointBelowRim.dy;

    final predictedX = x1 + (x2 - x1) * (rimHeight - y1) / (y2 - y1);

    // Calculate rim boundaries (use 0.8 * diameter for make detection)
    final rimLeft = hoopPosition.dx - (hoopRadius * 0.8);
    final rimRight = hoopPosition.dx + (hoopRadius * 0.8);

    final willMake = predictedX >= rimLeft && predictedX <= rimRight;

    debugPrint(
      '🏀 Rim crossing at x=${predictedX.toStringAsFixed(1)} '
      '(rim: ${rimLeft.toStringAsFixed(1)} - ${rimRight.toStringAsFixed(1)}) '
      '→ ${willMake ? "MAKE" : "MISS"}',
    );

    return willMake;
  }

  /// Calculate shot accuracy as percentage (0-100%)
  /// Based on how close the ball crosses the rim to the center
  /// Supports dynamic hoop tracking for moving cameras
  static ShotAccuracyResult calculateShotAccuracyFromRimCrossing({
    required List<Offset> ballPoints,
    required Offset hoopPosition,
    BoundingBox? hoopBBox,
    double hoopRadius = 30.0,
  }) {
    // Copy list to avoid modifying original, then densify.
    final points = List<Offset>.from(ballPoints);
    final int originalLength = points.length;
    for (int i = 1; i < originalLength; i++) {
      final inBetween = Offset.lerp(points[i - 1], points[i], 0.5)!;
      final insertPoint = Offset.lerp(points[i - 1], inBetween, 0.5)!;
      points.insert(i, insertPoint);
    }

    if (points.length < 3) {
      return ShotAccuracyResult(
        accuracy: 0.0,
        confidence: ShotConfidence.insufficient,
        reason: 'Not enough trajectory points',
      );
    }

    final rimCenterX = hoopBBox != null ? hoopBBox.centerX : hoopPosition.dx;
    final rimWidth = hoopBBox != null ? hoopBBox.width : (hoopRadius * 2);
    // Measure the crossing at the ring's *centre* height — where the ball
    // actually passes through the opening. Using the rim's top edge (the old
    // behaviour) sampled the arc too early and mis-scored genuine crossings.
    final lineY = hoopPosition.dy;

    // Scan every segment for a crossing of the rim centre line and keep the one
    // whose interpolated X is nearest the rim centre — that's the segment where
    // the ball went through the opening (robust to noise and multiple grazes).
    double? crossX;
    for (int i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final dy = b.dy - a.dy;
      if (dy.abs() < 1e-6) continue; // horizontal segment — no clean crossing
      final straddles =
          (a.dy <= lineY && b.dy >= lineY) || (a.dy >= lineY && b.dy <= lineY);
      if (!straddles) continue;
      final t = (lineY - a.dy) / dy;
      final x = a.dx + (b.dx - a.dx) * t;
      if (crossX == null ||
          (x - rimCenterX).abs() < (crossX - rimCenterX).abs()) {
        crossX = x;
      }
    }

    if (crossX == null) {
      // No rim-plane crossing (partial arc) — estimate from closest approach.
      return _estimateAccuracyFromProximity(
        points: points,
        hoopPosition: hoopPosition,
        hoopBBox: hoopBBox,
        hoopRadius: hoopRadius,
      );
    }

    final distanceFromCenter = (crossX - rimCenterX).abs();

    // Perfect center = 100%, edge = ~0%, outside = negative (clamped to 0)
    final accuracy = ((1 - (distanceFromCenter / (rimWidth / 2))) * 100).clamp(
      0.0,
      100.0,
    );

    // Determine confidence based on trajectory completeness
    final hasFullArc = _hasCompleteArc(points, lineY);
    final confidence = hasFullArc ? ShotConfidence.high : ShotConfidence.medium;

    debugPrint(
      '📊 Shot Accuracy: ${accuracy.toStringAsFixed(1)}% '
      '(confidence: $confidence, distance: ${distanceFromCenter.toStringAsFixed(1)}px)',
    );

    return ShotAccuracyResult(
      accuracy: accuracy,
      confidence: confidence,
      reason: 'Rim crossing detected',
    );
  }

  /// Fallback method: estimate accuracy from closest approach to rim
  /// Used when rim crossing isn't detected (partial trajectory)
  static ShotAccuracyResult _estimateAccuracyFromProximity({
    required List<Offset> points,
    required Offset hoopPosition,
    BoundingBox? hoopBBox,
    double hoopRadius = 30.0,
  }) {
    // Find closest point to rim
    double closestDistance = double.infinity;
    Offset? closestPoint;

    for (final point in points) {
      final distance = (point - hoopPosition).distance;
      if (distance < closestDistance) {
        closestDistance = distance;
        closestPoint = point;
      }
    }

    if (closestPoint == null) {
      return ShotAccuracyResult(
        accuracy: 0.0,
        confidence: ShotConfidence.insufficient,
        reason: 'No trajectory data',
      );
    }

    final rimWidth = hoopBBox != null ? hoopBBox.width : (hoopRadius * 2);

    // If ball never got close to rim, it's clearly a miss
    if (closestDistance > rimWidth * 2) {
      return ShotAccuracyResult(
        accuracy: 0.0,
        confidence: ShotConfidence.low,
        reason:
            'Ball too far from rim (${closestDistance.toStringAsFixed(0)}px)',
      );
    }

    // Estimate accuracy based on proximity
    // Within rim width = some accuracy, farther = lower
    final accuracy = ((1 - (closestDistance / (rimWidth * 1.5))) * 100).clamp(
      0.0,
      100.0,
    );

    debugPrint(
      '⚠️ Partial trajectory - estimated accuracy: ${accuracy.toStringAsFixed(1)}% '
      '(closest: ${closestDistance.toStringAsFixed(1)}px)',
    );

    return ShotAccuracyResult(
      accuracy: accuracy,
      confidence: ShotConfidence.low,
      reason: 'Partial trajectory - estimated from proximity',
    );
  }

  /// Check if trajectory contains a complete arc (ascent + descent)
  static bool _hasCompleteArc(List<Offset> points, double rimHeight) {
    if (points.length < 5) return false;

    bool hasPointsAboveRim = points.any((p) => p.dy < rimHeight);
    bool hasPointsBelowRim = points.any((p) => p.dy > rimHeight);

    // Check for ascending phase (Y decreasing)
    bool hasAscent = false;
    for (int i = 1; i < points.length; i++) {
      if (points[i].dy < points[i - 1].dy) {
        hasAscent = true;
        break;
      }
    }

    return hasPointsAboveRim && hasPointsBelowRim && hasAscent;
  }

  /// Check whether any frame in [frames] contains a "made" detection near
  /// [targetHoopPosition]. The model emits a "made" label when the ball is
  /// visually inside the hoop, giving direct evidence that the shot went in
  /// regardless of whether the Y-axis rim-crossing geometry fired.
  ///
  /// [proximityThreshold] is the max distance (px) between the "made"
  /// detection center and the target hoop center. A generous default (200 px)
  /// handles both backboard and sideways view where coordinates can differ.
  ///
  /// Returns a high-confidence MAKE result when found, null otherwise.
  static ShotAccuracyResult? checkMadeDetection(
    List<FrameData> frames,
    Offset targetHoopPosition, {
    double proximityThreshold = 200.0,
  }) {
    for (final frame in frames) {
      for (final d in frame.detections) {
        if (d.isMade) {
          final pos = d.center;
          final dist = (pos - targetHoopPosition).distance;
          if (dist <= proximityThreshold) {
            debugPrint(
              '✅ "made" label detected at (${pos.dx.toInt()}, ${pos.dy.toInt()}) '
              '— ${dist.toStringAsFixed(0)}px from target hoop',
            );
            return ShotAccuracyResult(
              accuracy: 95.0,
              confidence: ShotConfidence.high,
              reason: '"made" label detected by model',
            );
          }
        }
      }
    }
    return null;
  }

  /// Perform linear regression for either X or Y coordinates
  static LinearRegressionResult? _performLinearRegression(
    List<Offset> points,
    bool useX, // true for X coordinates, false for Y coordinates
  ) {
    if (points.length < 2) return null;

    double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
    final n = points.length;

    for (int i = 0; i < n; i++) {
      final x = i.toDouble(); // time index
      final y = useX ? points[i].dx : points[i].dy; // position coordinate

      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumXX += x * x;
    }

    // Calculate slope and intercept
    final denominator = n * sumXX - sumX * sumX;
    if (denominator == 0) return null; // Avoid division by zero

    final slope = (n * sumXY - sumX * sumY) / denominator;
    final intercept = (sumY - slope * sumX) / n;

    return LinearRegressionResult(slope: slope, intercept: intercept);
  }
}

class LinearRegressionResult {
  final double slope;
  final double intercept;

  LinearRegressionResult({required this.slope, required this.intercept});
}

enum ShotConfidence {
  high, // Complete trajectory with rim crossing
  medium, // Partial trajectory with rim crossing
  low, // Estimated from proximity only
  insufficient, // Not enough data
}

class ShotAccuracyResult {
  final double accuracy; // 0-100%
  final ShotConfidence confidence; // How reliable is this measurement
  final String reason; // Why this confidence level

  ShotAccuracyResult({
    required this.accuracy,
    required this.confidence,
    required this.reason,
  });

  bool get isReliable =>
      confidence == ShotConfidence.high || confidence == ShotConfidence.medium;
}
