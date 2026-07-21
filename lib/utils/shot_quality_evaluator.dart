import 'dart:math';
import 'package:flutter/material.dart';
import 'package:hooplab/models/recording_mode.dart';

/// Camera-geometry tuning for the ball-flight (arc + release-angle) scoring.
///
/// The *same* real shot projects to a different on-screen arc depending on the
/// rig. The default reproduces the tripod (near-true-geometry) bands. In
/// **ground** mode the phone is tilted up, which foreshortens the vertical axis:
/// a genuine 50° release reads as a much shallower on-screen angle and the arc
/// looks flatter, so the "good" bands are shifted lower — otherwise a perfectly
/// good shot filmed from the ground would always be marked as too flat.
class ShotArcProfile {
  /// Release-angle band that scores a full 1.0 (degrees, on screen).
  final double releaseIdealLow;
  final double releaseIdealHigh;

  /// Wider band that still scores partially (outside it → 0.2).
  final double releaseAcceptLow;
  final double releaseAcceptHigh;

  /// Degrees of falloff used to grade angles inside the accept band.
  final double releaseFalloff;

  /// Arc-height ratio (peak rise ÷ vertical distance to hoop) that scores 1.0.
  final double arcRatioIdealLow;
  final double arcRatioIdealHigh;

  /// Wider arc-ratio band that still scores 0.7.
  final double arcRatioOkLow;
  final double arcRatioOkHigh;

  const ShotArcProfile({
    this.releaseIdealLow = 45,
    this.releaseIdealHigh = 55,
    this.releaseAcceptLow = 35,
    this.releaseAcceptHigh = 65,
    this.releaseFalloff = 20,
    this.arcRatioIdealLow = 1.2,
    this.arcRatioIdealHigh = 1.8,
    this.arcRatioOkLow = 0.8,
    this.arcRatioOkHigh = 2.2,
  });

  factory ShotArcProfile.forMode(RecordingMode mode) => switch (mode) {
        RecordingMode.tripod => const ShotArcProfile(),
        RecordingMode.ground => const ShotArcProfile(
            releaseIdealLow: 30,
            releaseIdealHigh: 48,
            releaseAcceptLow: 20,
            releaseAcceptHigh: 60,
            releaseFalloff: 22,
            arcRatioIdealLow: 0.7,
            arcRatioIdealHigh: 1.3,
            arcRatioOkLow: 0.45,
            arcRatioOkHigh: 1.7,
          ),
      };
}

/// Evaluates shot quality based on form/technique, not whether it went in
class ShotQualityEvaluator {
  /// Calculate shot quality score (0-100) based on multiple factors
  /// Higher score = better shooting form/technique
  static ShotQualityResult evaluateShotQuality({
    required List<Offset> ballTrajectory,
    required Offset hoopPosition,
    double hoopRadius = 30.0,
    ShotArcProfile profile = const ShotArcProfile(),
  }) {
    if (ballTrajectory.length < 5) {
      return ShotQualityResult(
        overallScore: 0.0,
        arcScore: 0.0,
        releaseAngleScore: 0.0,
        distanceScore: 0.0,
        consistencyScore: 0.0,
        cues: const [],
        feedback: 'Not enough data to evaluate shot',
      );
    }

    // 1. Arc Quality (0-30 points) - Does the ball have a good arc?
    final arcScore = _evaluateArc(ballTrajectory, hoopPosition, profile);

    // 2. Release Angle (0-25 points) - Is the initial trajectory angle good?
    final releaseAngleScore = _evaluateReleaseAngle(ballTrajectory, profile);

    // 3. Distance to Target (0-25 points) - How close did it get to the hoop?
    final distanceScore = _evaluateDistanceToHoop(
      ballTrajectory,
      hoopPosition,
      hoopRadius,
    );

    // 4. Trajectory Consistency (0-20 points) - Is the arc smooth?
    final consistencyScore = _evaluateTrajectoryConsistency(ballTrajectory);

    // Overall score out of 100
    final overallScore =
        (arcScore + releaseAngleScore + distanceScore + consistencyScore).clamp(
          0.0,
          100.0,
        );

    // Generate feedback
    final cues = _generateCues(
      arcScore: arcScore,
      releaseAngleScore: releaseAngleScore,
      distanceScore: distanceScore,
      consistencyScore: consistencyScore,
    );

    return ShotQualityResult(
      overallScore: overallScore,
      arcScore: arcScore,
      releaseAngleScore: releaseAngleScore,
      distanceScore: distanceScore,
      consistencyScore: consistencyScore,
      cues: cues,
      feedback: cues.join(' • '),
    );
  }

  /// Evaluate the arc quality (parabolic shape)
  static double _evaluateArc(
    List<Offset> trajectory,
    Offset hoopPosition,
    ShotArcProfile profile,
  ) {
    if (trajectory.length < 5) return 0.0;

    // Find the highest point in the trajectory
    double maxY = trajectory.first.dy;
    int peakIndex = 0;

    for (int i = 0; i < trajectory.length; i++) {
      if (trajectory[i].dy < maxY) {
        // invert y to account for coordinate system change on viewport
        maxY = trajectory[i].dy;
        peakIndex = i;
      }
    }

    // Good arc: peak should be roughly in the middle third of the trajectory
    final idealPeakPosition = trajectory.length / 2;
    final peakPositionError =
        (peakIndex - idealPeakPosition).abs() / trajectory.length;

    double peakPositionScore = (1 - peakPositionError * 2).clamp(0.0, 1.0);

    // Calculate arc height relative to hoop
    final startY = trajectory.first.dy;
    final arcHeight = startY - maxY;
    final verticalDistanceToHoop = (startY - hoopPosition.dy).abs();

    // Ideal arc height is 1.2x to 1.8x the vertical distance to hoop
    final arcHeightRatio = verticalDistanceToHoop > 0
        ? arcHeight / verticalDistanceToHoop
        : 0;

    double arcHeightScore;
    if (arcHeightRatio >= profile.arcRatioIdealLow &&
        arcHeightRatio <= profile.arcRatioIdealHigh) {
      arcHeightScore = 1.0; // good arc height
    } else if (arcHeightRatio >= profile.arcRatioOkLow &&
        arcHeightRatio <= profile.arcRatioOkHigh) {
      arcHeightScore = 0.7; // Acceptable
    } else {
      arcHeightScore = 0.3; // Too flat / high
    }

    // Combine scores (maximum of 30 points)
    return (peakPositionScore * 15 + arcHeightScore * 15);
  }

  /// Evaluate the release angle. The "good" band is supplied by [profile]
  /// because the on-screen angle of a given real release depends on the camera
  /// rig (a tilted-up ground shot foreshortens the vertical, reading flatter).
  static double _evaluateReleaseAngle(
    List<Offset> trajectory,
    ShotArcProfile profile,
  ) {
    if (trajectory.length < 3) return 0.0;

    // Calculate initial trajectory angle from first 3 points
    final p1 = trajectory[0];
    final p2 = trajectory[min(2, trajectory.length - 1)];

    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;

    // Calculate angle in degrees (negative dy = upward)
    final angleRadians = atan2(-dy, dx);
    final angleDegrees = angleRadians * 180 / pi;

    double angleScore;
    if (angleDegrees >= profile.releaseIdealLow &&
        angleDegrees <= profile.releaseIdealHigh) {
      angleScore = 1.0; // in the ideal band
    } else if (angleDegrees >= profile.releaseAcceptLow &&
        angleDegrees <= profile.releaseAcceptHigh) {
      final deviation = min(
        (angleDegrees - profile.releaseIdealLow).abs(),
        (angleDegrees - profile.releaseIdealHigh).abs(),
      );
      angleScore = 1.0 - (deviation / profile.releaseFalloff); // Gradual falloff
    } else {
      angleScore = 0.2; // Too flat or too steep
    }

    return angleScore * 25; // Max 25 points
  }

  /// Evaluate how close the ball got to the hoop
  static double _evaluateDistanceToHoop(
    List<Offset> trajectory,
    Offset hoopPosition,
    double hoopRadius,
  ) {
    // Find closest point to hoop
    double closestDistance = double.infinity;

    for (final point in trajectory) {
      final distance = (point - hoopPosition).distance;
      if (distance < closestDistance) {
        closestDistance = distance;
      }
    }

    // DISTANCE BASED SCORING ON HOW CLOSE IT GOT TO THE HOOP
    double distanceScore;

    if (closestDistance <= hoopRadius) {
      distanceScore = 1.0; // very close
    } else if (closestDistance <= hoopRadius * 2) {
      distanceScore = 1.0 - ((closestDistance - hoopRadius) / hoopRadius) * 0.5;
    } else if (closestDistance <= hoopRadius * 3) {
      distanceScore =
          0.5 - ((closestDistance - hoopRadius * 2) / hoopRadius) * 0.4;
    } else {
      distanceScore = 0.1; // far off from hoop
    }

    return distanceScore * 25; // Max 25 points
  }

  /// Evaluate trajectory smoothness (less jitter = better)
  static double _evaluateTrajectoryConsistency(List<Offset> trajectory) {
    if (trajectory.length < 4) return 0.0;

    // Calculate direction changes
    List<double> angles = [];

    for (int i = 1; i < trajectory.length - 1; i++) {
      // CREATE THREE POINTS FOR ANGLE CALCULATION
      final p1 = trajectory[i - 1];
      final p2 = trajectory[i];
      final p3 = trajectory[i + 1];

      // CALCULATE ANGLE BETWEEN THE TWO VECTORS
      final dx1 = p2.dx - p1.dx;
      final dy1 = p2.dy - p1.dy;
      final dx2 = p3.dx - p2.dx;
      final dy2 = p3.dy - p2.dy;

      final angle1 = atan2(dy1, dx1);
      final angle2 = atan2(dy2, dx2);

      final angleChange = (angle2 - angle1).abs();
      angles.add(angleChange);
    }

    if (angles.isEmpty) return 10.0;

    // Calculate average angle change
    final avgAngleChange = angles.reduce((a, b) => a + b) / angles.length;

    // Lower angle change = smoother trajectory
    // Smooth shot: < 0.2 radians average change
    // Rough shot: > 0.5 radians average change
    double consistencyScore;
    if (avgAngleChange < 0.2) {
      consistencyScore = 1.0;
    } else if (avgAngleChange < 0.5) {
      consistencyScore = 1.0 - ((avgAngleChange - 0.2) / 0.3);
    } else {
      consistencyScore = 0.2;
    }

    return consistencyScore * 20; // Max 20 points
  }

  /// Specific, actionable cues drawn from the ball flight only (the body
  /// mechanics — arm angles, knee bend — are covered separately by
  /// [ShootingFormAnalyzer]). Ordered most-impactful first; empty when the
  /// flight looks clean.
  static List<String> _generateCues({
    required double arcScore,
    required double releaseAngleScore,
    required double distanceScore,
    required double consistencyScore,
  }) {
    final cues = <String>[];

    // Arc + release angle both speak to trajectory shape; lead with whichever
    // is weaker so we don't stack two near-identical "arc" notes.
    if (releaseAngleScore < 15) {
      cues.add('Raise your release angle toward 45–55° for a softer arc.');
    } else if (arcScore < 18) {
      cues.add('Arc is flat — get more height so the ball drops into the rim.');
    }

    if (consistencyScore < 12) {
      cues.add('Smooth out the release — the ball flight is wobbling.');
    }
    if (distanceScore < 15) {
      cues.add('Dial in your aim — the ball missed the rim by a wide margin.');
    }

    return cues;
  }
}

// DATA CLASS TO STORE INFORMATION
class ShotQualityResult {
  final double overallScore; // 0-100
  final double arcScore; // 0-30
  final double releaseAngleScore; // 0-25
  final double distanceScore; // 0-25
  final double consistencyScore; // 0-20
  final List<String> cues; // specific ball-flight cues, most-impactful first
  final String feedback; // cues joined for single-line display

  ShotQualityResult({
    required this.overallScore,
    required this.arcScore,
    required this.releaseAngleScore,
    required this.distanceScore,
    required this.consistencyScore,
    required this.cues,
    required this.feedback,
  });
}
