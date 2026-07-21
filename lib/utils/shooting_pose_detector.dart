import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
// Import dart:math for calculations
import 'dart:math';

/// Helper class to detect basketball shooting poses using Google ML Kit
class ShootingPoseDetector {
  final PoseDetector _poseDetector;

  // Track shooting state
  bool _isInShootingMotion = false;
  DateTime? _shootingStartTime;

  ShootingPoseDetector({PoseDetectorOptions? options})
    : _poseDetector = PoseDetector(
        options:
            options ??
            PoseDetectorOptions(
              mode: PoseDetectionMode.stream,
              model: PoseDetectionModel.accurate,
            ),
      );

  /// Detect poses in an image and return shooting motion status
  /// Optional ballPosition to identify which person is holding the ball
  Future<ShootingPoseResult> detectShootingPose(
    InputImage image, {
    Offset? ballPosition,
  }) async {
    try {
      final poses = await _poseDetector.processImage(image);

      debugPrint('🔍 Pose detector found ${poses.length} poses');

      if (poses.isEmpty) {
        debugPrint('⚠️ No poses detected in this frame');
        return ShootingPoseResult(
          isShootingMotion: false,
          poses: [],
          shootingConfidence: 0.0,
        );
      }

      // If ball position is provided, prioritize the person closest to the ball
      Pose? ballHolderPose;
      if (ballPosition != null && poses.length > 1) {
        ballHolderPose = _findBallHolder(poses, ballPosition);
        if (ballHolderPose != null) {
          debugPrint('🎯 Ball holder identified among ${poses.length} people');
        }
      }

      // Analyze poses for shooting motion
      // Prioritize ball holder if found, otherwise check all poses
      double maxShootingConfidence = 0.0;
      Pose? shootingPose;

      if (ballHolderPose != null) {
        // Only analyze the person holding the ball
        maxShootingConfidence = _analyzeShootingMotion(ballHolderPose);
        shootingPose = ballHolderPose;
        debugPrint(
          '🏀 Analyzing ball holder: confidence=${maxShootingConfidence.toStringAsFixed(2)}',
        );
      } else {
        // Analyze all poses and pick the one with highest shooting confidence
        for (final pose in poses) {
          final confidence = _analyzeShootingMotion(pose);
          if (confidence > maxShootingConfidence) {
            maxShootingConfidence = confidence;
            shootingPose = pose;
          }
        }
      }

      // Consider it a shooting motion above this confidence. Kept moderate so a
      // clearly raised/extended arm counts even when only one side of the body
      // is visible (common in sideways/court footage).
      final isCurrentlyShooting = maxShootingConfidence > 0.5;

      // Track shooting state transitions
      if (isCurrentlyShooting && !_isInShootingMotion) {
        _isInShootingMotion = true;
        _shootingStartTime = DateTime.now();
        debugPrint(
          '🏀 Shooting motion detected! Confidence: ${maxShootingConfidence.toStringAsFixed(2)}',
        );
      } else if (!isCurrentlyShooting && _isInShootingMotion) {
        _isInShootingMotion = false;
        final duration = _shootingStartTime != null
            ? DateTime.now().difference(_shootingStartTime!).inMilliseconds
            : 0;
        debugPrint('🏀 Shooting motion ended after ${duration}ms');
        _shootingStartTime = null;
      }

      return ShootingPoseResult(
        isShootingMotion: _isInShootingMotion,
        poses: shootingPose != null
            ? [shootingPose]
            : poses, // Return only ball holder's pose if identified
        shootingConfidence: maxShootingConfidence,
        shootingPose: shootingPose,
        shootingDuration: _shootingStartTime != null
            ? DateTime.now().difference(_shootingStartTime!)
            : null,
      );
    } catch (e, stackTrace) {
      debugPrint('❌ Error detecting pose: $e');
      debugPrint('Stack trace: $stackTrace');
      return ShootingPoseResult(
        isShootingMotion: false,
        poses: [],
        shootingConfidence: 0.0,
      );
    }
  }

  /// Find which person is holding/closest to the ball
  Pose? _findBallHolder(List<Pose> poses, Offset ballPosition) {
    Pose? closestPose;
    double minDistance = double.infinity;

    for (final pose in poses) {
      final landmarks = pose.landmarks;

      // Check distance from ball to person's hands (wrists)
      final rightWrist = landmarks[PoseLandmarkType.rightWrist];
      final leftWrist = landmarks[PoseLandmarkType.leftWrist];

      double poseDistance = double.infinity;

      // Calculate distance to right hand
      if (rightWrist != null) {
        final wristPos = Offset(rightWrist.x, rightWrist.y);
        final distance = (ballPosition - wristPos).distance;
        if (distance < poseDistance) {
          poseDistance = distance;
        }
      }

      // Calculate distance to left hand
      if (leftWrist != null) {
        final wristPos = Offset(leftWrist.x, leftWrist.y);
        final distance = (ballPosition - wristPos).distance;
        if (distance < poseDistance) {
          poseDistance = distance;
        }
      }

      // Also check torso center (for when ball is at chest)
      final leftShoulder = landmarks[PoseLandmarkType.leftShoulder];
      final rightShoulder = landmarks[PoseLandmarkType.rightShoulder];

      if (leftShoulder != null && rightShoulder != null) {
        final torsoCenter = Offset(
          (leftShoulder.x + rightShoulder.x) / 2,
          (leftShoulder.y + rightShoulder.y) / 2,
        );
        final distance = (ballPosition - torsoCenter).distance;
        if (distance < poseDistance) {
          poseDistance = distance;
        }
      }

      // Track closest person to ball
      if (poseDistance < minDistance) {
        minDistance = poseDistance;
        closestPose = pose;
      }
    }

    // Only consider it a ball holder if within reasonable distance (200 pixels)
    if (minDistance < 200) {
      debugPrint('  Ball holder distance: ${minDistance.toStringAsFixed(1)}px');
      return closestPose;
    }

    return null;
  }

  /// Analyze a pose to determine if it's a basketball shooting motion.
  /// Returns confidence score 0.0-1.0.
  ///
  /// Scored per-arm and takes the best side, so a shot is still detected when
  /// only one side of the body is visible (sideways/court footage frequently
  /// occludes the far arm). A both-arms "set shot" adds a small bonus.
  double _analyzeShootingMotion(Pose pose) {
    final landmarks = pose.landmarks;

    double sideScore(
      PoseLandmarkType shoulderType,
      PoseLandmarkType elbowType,
      PoseLandmarkType wristType,
    ) {
      final shoulder = landmarks[shoulderType];
      final wrist = landmarks[wristType];
      // Shoulder + wrist are the minimum needed to judge a raised arm.
      if (shoulder == null || wrist == null) return 0.0;

      double c = 0.0;
      // Core cue: wrist above the shoulder (arm raised to shoot).
      if (wrist.y < shoulder.y) c += 0.45;
      // Arm meaningfully extended upward.
      if ((shoulder.y - wrist.y) > 40) c += 0.30;
      // Elbow angle in the shooting range (arm extending overhead).
      final elbow = landmarks[elbowType];
      if (elbow != null) {
        final angle = _calculateAngle(shoulder, elbow, wrist);
        if (angle >= 80 && angle <= 170) c += 0.25;
      }
      return c;
    }

    double best = sideScore(
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.rightWrist,
    );
    final leftScore = sideScore(
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.leftWrist,
    );
    if (leftScore > best) best = leftScore;

    // Both-arms "set shot" bonus: both wrists raised and close together.
    final rightWrist = landmarks[PoseLandmarkType.rightWrist];
    final leftWrist = landmarks[PoseLandmarkType.leftWrist];
    final rightShoulder = landmarks[PoseLandmarkType.rightShoulder];
    final leftShoulder = landmarks[PoseLandmarkType.leftShoulder];
    if (rightWrist != null &&
        leftWrist != null &&
        rightShoulder != null &&
        leftShoulder != null) {
      final bothRaised =
          rightWrist.y < rightShoulder.y && leftWrist.y < leftShoulder.y;
      if (bothRaised && (rightWrist.x - leftWrist.x).abs() < 160) {
        best += 0.15;
      }
    }

    return best.clamp(0.0, 1.0);
  }

  /// Calculate angle between three points (in degrees)
  double _calculateAngle(
    PoseLandmark? point1,
    PoseLandmark? point2,
    PoseLandmark? point3,
  ) {
    if (point1 == null || point2 == null || point3 == null) {
      return 0.0;
    }

    // Vector from point2 to point1
    final dx1 = point1.x - point2.x;
    final dy1 = point1.y - point2.y;

    // Vector from point2 to point3
    final dx2 = point3.x - point2.x;
    final dy2 = point3.y - point2.y;

    // Calculate angle using dot product
    final dotProduct = dx1 * dx2 + dy1 * dy2;
    final magnitude1 = sqrt(dx1 * dx1 + dy1 * dy1);
    final magnitude2 = sqrt(dx2 * dx2 + dy2 * dy2);

    if (magnitude1 == 0 || magnitude2 == 0) return 0.0;

    final cosAngle = dotProduct / (magnitude1 * magnitude2);
    final angleRadians = acos(cosAngle.clamp(-1.0, 1.0));
    final angleDegrees = angleRadians * 180 / pi;

    return angleDegrees;
  }

  /// Clean up resources
  void dispose() {
    _poseDetector.close();
  }
}

/// Result from shooting pose detection
class ShootingPoseResult {
  final bool isShootingMotion;
  final List<Pose> poses;
  final double shootingConfidence;
  final Pose? shootingPose;
  final Duration? shootingDuration;

  ShootingPoseResult({
    required this.isShootingMotion,
    required this.poses,
    required this.shootingConfidence,
    this.shootingPose,
    this.shootingDuration,
  });
}
