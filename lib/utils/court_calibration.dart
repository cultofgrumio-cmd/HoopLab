import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/utils/court.dart';

/// How well the court is calibrated for a session. Each tier is optional and the
/// map degrades gracefully — a shot always gets *a* location, just a more
/// accurate one the higher the tier.
///
///  * [none] — no calibration. Shot locations are estimated rim-relative using
///    the rim's known ~18" width as a scale reference (approximate, but needs
///    nothing from the user).
///  * [freeThrow] — the user tagged one free throw. Its foot position is a known
///    court point (centred, 13.75' from the basket), which fixes the court's
///    scale *and* orientation via a similarity transform.
///  * [multiSpot] — reserved for a future homography from several tagged spots.
enum CalibrationTier { none, freeThrow, multiSpot }

extension CalibrationTierInfo on CalibrationTier {
  String get label => switch (this) {
        CalibrationTier.none => 'Approximate',
        CalibrationTier.freeThrow => 'Calibrated (free throw)',
        CalibrationTier.multiSpot => 'Precise',
      };

  /// Short badge text.
  String get badge => switch (this) {
        CalibrationTier.none => 'Approx',
        CalibrationTier.freeThrow => 'Calibrated',
        CalibrationTier.multiSpot => 'Precise',
      };

  String get storageKey => name;

  static CalibrationTier fromStorageKey(String? key) {
    for (final t in CalibrationTier.values) {
      if (t.name == key) return t;
    }
    return CalibrationTier.none;
  }
}

/// A court location together with the zone it falls in.
class ShotLocation {
  final Offset courtFeet; // origin at the basket, +x right, +y out
  final CourtZone zone;

  const ShotLocation({required this.courtFeet, required this.zone});
}

/// Maps a shot's image-space foot anchor onto the court, using whatever
/// calibration is available. Serializable so a session remembers how its shots
/// were located (and can be recomputed if the tier is upgraded later).
class CourtCalibration {
  final CalibrationTier tier;

  /// Free-throw calibration anchors (image pixels). The rim centre maps to the
  /// basket `(0,0)` and the free-throw foot anchor maps to `(0, 13.75)`.
  final Offset? rimPixel;
  final Offset? freeThrowPixel;

  const CourtCalibration({
    this.tier = CalibrationTier.none,
    this.rimPixel,
    this.freeThrowPixel,
  });

  static const CourtCalibration none = CourtCalibration();

  /// Build a Tier-1 calibration from a tagged free throw: the shooter's foot
  /// anchor and the rim centre, both in image pixels.
  factory CourtCalibration.fromFreeThrow({
    required Offset freeThrowFootAnchor,
    required Offset rimCenter,
  }) =>
      CourtCalibration(
        tier: CalibrationTier.freeThrow,
        rimPixel: rimCenter,
        freeThrowPixel: freeThrowFootAnchor,
      );

  bool get isCalibrated => tier != CalibrationTier.none;

  /// Locate a shot from its foot anchor. [rimCenter] and [rimWidth] are the
  /// per-shot rim (used for the uncalibrated rim-relative estimate, and as a
  /// fallback if a higher-tier transform is degenerate).
  ShotLocation? locate(
    Offset? footAnchor, {
    Offset? rimCenter,
    double? rimWidth,
  }) {
    if (footAnchor == null) return null;

    Offset? court;
    if (tier == CalibrationTier.freeThrow) {
      court = _freeThrowImageToCourt(footAnchor);
    }
    court ??= _rimRelative(footAnchor, rimCenter, rimWidth);
    if (court == null) return null;

    return ShotLocation(courtFeet: court, zone: classifyZone(court));
  }

  /// Tier-1 similarity transform (rotation + uniform scale + translation) built
  /// from the two known correspondences. Orientation-preserving, so it's fully
  /// determined by two points — at the cost of not being able to tell the two
  /// (mirror-image) sides of the court apart, which a Tier-2 homography would.
  Offset? _freeThrowImageToCourt(Offset p) {
    final rim = rimPixel;
    final ft = freeThrowPixel;
    if (rim == null || ft == null) return null;

    final axis = ft - rim; // image basket→free-throw, maps to court (0, +13.75)
    final len = axis.distance;
    if (len < 1e-6) return null;

    final scale = CourtDimensions.freeThrowLineY / len; // feet per pixel
    final yHat = Offset(axis.dx / len, axis.dy / len); // → court +y (out)
    final xHat = Offset(yHat.dy, -yHat.dx); // → court +x (right)

    final v = p - rim;
    final cx = (v.dx * xHat.dx + v.dy * xHat.dy) * scale;
    final cy = (v.dx * yHat.dx + v.dy * yHat.dy) * scale;
    return Offset(cx, cy);
  }

  /// Tier-0 estimate: no orientation info, so assume the image axes roughly
  /// align with the court (screen-down ≈ out from the basket) and scale by the
  /// rim's known ~18" width. Deliberately approximate.
  Offset? _rimRelative(Offset foot, Offset? rimCenter, double? rimWidth) {
    if (rimCenter == null || rimWidth == null || rimWidth <= 1e-6) return null;
    final scale = (CourtDimensions.rimRadius * 2) / rimWidth; // feet per pixel
    final v = foot - rimCenter;
    return Offset(v.dx * scale, v.dy * scale);
  }

  Map<String, dynamic> toJson() => {
        'tier': tier.storageKey,
        if (rimPixel != null)
          'rim_pixel': {'dx': rimPixel!.dx, 'dy': rimPixel!.dy},
        if (freeThrowPixel != null)
          'free_throw_pixel': {'dx': freeThrowPixel!.dx, 'dy': freeThrowPixel!.dy},
      };

  factory CourtCalibration.fromJson(Map<String, dynamic> json) {
    Offset? readOffset(dynamic o) => o == null
        ? null
        : Offset((o['dx'] as num).toDouble(), (o['dy'] as num).toDouble());
    return CourtCalibration(
      tier: CalibrationTierInfo.fromStorageKey(json['tier'] as String?),
      rimPixel: readOffset(json['rim_pixel']),
      freeThrowPixel: readOffset(json['free_throw_pixel']),
    );
  }
}

/// Extracts the shooter's on-floor position (the "foot anchor") from a shot's
/// frames, layered by reliability so it degrades gracefully:
///   1. the midpoint of the shooter's ankles from the pose track,
///   2. the bottom-centre of the `person` detection box,
///   3. the ball's release point offset downward by a body height.
class FootAnchorEstimator {
  const FootAnchorEstimator._();

  static const double _minLikelihood = 0.3;

  /// Returns the foot anchor in image pixels, or null if nothing usable exists.
  static Offset? estimate(List<FrameData> frames, {double? rimWidth}) {
    return _fromPoseAnkles(frames) ??
        _fromPersonBox(frames) ??
        _fromBallRelease(frames, rimWidth);
  }

  static Offset? _fromPoseAnkles(List<FrameData> frames) {
    final pts = <Offset>[];
    for (final f in frames) {
      final poses = f.poses;
      if (poses == null || poses.isEmpty) continue;
      final anchor = _footFromPose(poses.first);
      if (anchor != null) pts.add(anchor);
    }
    return _median(pts);
  }

  /// Foot point from a single pose: prefer ankles, fall back to heels then the
  /// foot-index landmarks. Averages both sides when both are present.
  static Offset? _footFromPose(Pose pose) {
    Offset? sideFoot(PoseLandmarkType ankle, PoseLandmarkType heel,
        PoseLandmarkType toe) {
      for (final type in [ankle, heel, toe]) {
        final lm = pose.landmarks[type];
        if (lm != null && lm.likelihood >= _minLikelihood) {
          return Offset(lm.x, lm.y);
        }
      }
      return null;
    }

    final left = sideFoot(PoseLandmarkType.leftAnkle, PoseLandmarkType.leftHeel,
        PoseLandmarkType.leftFootIndex);
    final right = sideFoot(PoseLandmarkType.rightAnkle,
        PoseLandmarkType.rightHeel, PoseLandmarkType.rightFootIndex);

    if (left != null && right != null) {
      return Offset((left.dx + right.dx) / 2, (left.dy + right.dy) / 2);
    }
    return left ?? right;
  }

  static Offset? _fromPersonBox(List<FrameData> frames) {
    final pts = <Offset>[];
    for (final f in frames) {
      final person = f.detections.where((d) => d.isPerson).fold<Detection?>(
            null,
            (best, d) => best == null || d.confidence > best.confidence ? d : best,
          );
      if (person == null) continue;
      final b = person.bbox;
      pts.add(Offset(b.centerX, math.max(b.y1, b.y2))); // bottom-centre = feet
    }
    return _median(pts);
  }

  static Offset? _fromBallRelease(List<FrameData> frames, double? rimWidth) {
    for (final f in frames) {
      final ball = f.detections.where((d) => d.isBall).firstOrNull;
      if (ball != null) {
        // The ball is released above the head; drop a rough body height to the
        // floor. Scaled by the rim width when known, else a fixed pixel guess.
        final drop = rimWidth != null ? rimWidth * 3.5 : 220.0;
        return Offset(ball.center.dx, ball.center.dy + drop);
      }
    }
    return null;
  }

  /// Component-wise median — robust to the odd stray landmark or detection.
  static Offset? _median(List<Offset> pts) {
    if (pts.isEmpty) return null;
    final xs = pts.map((p) => p.dx).toList()..sort();
    final ys = pts.map((p) => p.dy).toList()..sort();
    final mid = pts.length ~/ 2;
    return Offset(xs[mid], ys[mid]);
  }
}
