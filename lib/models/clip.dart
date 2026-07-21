import 'dart:ui';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class Clip {
  String id;
  String name;
  String videoPath;
  List<FrameData> frames;
  List<Shot> shots; // Multiple shots detected in the video

  Clip({
    required this.id,
    required this.name,
    required this.videoPath,
    required this.frames,
    List<Shot>? shots,
  }) : shots = shots ?? [];
}

class FrameData {
  int frameNumber;
  double timestamp;
  List<Detection> detections;
  bool isShootingMotion; // Whether someone is in shooting motion in this frame
  double shootingConfidence; // Confidence of shooting pose detection (0.0-1.0)
  List<Pose>? poses; // ML Kit pose data for visualization

  FrameData({
    required this.frameNumber,
    required this.timestamp,
    required this.detections,
    this.isShootingMotion = false,
    this.shootingConfidence = 0.0,
    this.poses,
  });
}

class Detection {
  int trackId;
  BoundingBox bbox;
  double confidence;
  double timestamp;
  String label;

  Detection({
    required this.trackId,
    required this.bbox,
    required this.confidence,
    required this.timestamp,
    required this.label,
  });

  Offset get center => Offset(bbox.centerX, bbox.centerY);
}

/// Canonical detection classes emitted by the YOLO model:
/// `0=ball, 1=made, 2=person, 3=rim, 4=shoot`.
///
/// The `ultralytics_yolo` plugin may surface either the string class name
/// (e.g. `"rim"`) or the numeric class id (e.g. `"3"`) depending on version,
/// so every check matches both. Legacy aliases (`hoop`/`basket`) are kept so
/// older/retrained models with those names keep working.
extension DetectionLabel on Detection {
  String get _l => label.toLowerCase().trim();

  bool get isBall => _l.contains('ball') || _l == '0';
  bool get isMade => _l.contains('made') || _l == '1';
  bool get isPerson => _l.contains('person') || _l == '2';
  bool get isRim =>
      _l.contains('rim') ||
      _l.contains('hoop') ||
      _l.contains('basket') ||
      _l == '3';
  bool get isShoot => _l.contains('shoot') || _l == '4';
}

class BoundingBox {
  double x1;
  double y1;
  double x2;
  double y2;

  BoundingBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  // Helper properties
  double get width => x2 - x1;
  double get height => y2 - y1;
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;

  // Convert to Rect for UI purposes
  Rect toRect() {
    return Rect.fromLTRB(x1, y1, x2, y2);
  }
}

// Shot class to represent a single basketball shot
class Shot {
  final int id;
  final List<FrameData> frames;
  final double startTime;
  final double endTime;
  String? prediction; // "MAKE • <feedback>" or "MISS • <feedback>"
  double? accuracy; // Shot accuracy percentage (0-100%)
  double? formScore; // Shooting-form quality score (0-100), independent of make/miss
  String? feedback; // Human-readable form feedback
  bool? predictedMake; // Predicted at release, before the outcome is visible
  double? predictedAccuracy; // Projected centeredness at the rim (0-100%)
  Offset? hoopPosition;
  Offset? footAnchor; // Shooter's on-floor position at release (image pixels)
  Offset? courtPosition; // Shot origin in court feet (basket at origin)
  String? zone; // CourtZone.name the shot was taken from
  double? rimWidth; // Rim bbox width in image pixels (scale reference)

  Shot({
    required this.id,
    required this.frames,
    required this.startTime,
    required this.endTime,
    this.prediction,
    this.accuracy,
    this.formScore,
    this.feedback,
    this.predictedMake,
    this.predictedAccuracy,
    this.hoopPosition,
    this.footAnchor,
    this.courtPosition,
    this.zone,
    this.rimWidth,
  });

  /// True when this shot was scored a make (accuracy above the make threshold).
  bool get isMake => prediction?.startsWith('MAKE') ?? false;

  List<Offset> get ballTrajectory {
    final points = <Offset>[];
    for (final frame in frames) {
      final ball = frame.detections.where((d) => d.isBall).firstOrNull;
      if (ball != null) points.add(ball.center);
    }
    return points;
  }
}
