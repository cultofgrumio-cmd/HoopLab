import 'dart:math' as math;
import 'dart:ui';

/// Half-court geometry and shot-zone classification for HoopLab's shot map.
///
/// Everything here works in a single **court coordinate system**, in feet, with
/// the origin at the basket (the point on the floor directly under the rim
/// centre):
///   * `+x` points to the court's right,
///   * `+y` points away from the baseline, out toward half court.
///
/// Detected shot locations (in image pixels) are converted into this system by
/// [CourtCalibration]; from there classification and rendering are purely
/// geometric and camera-independent, so a shot chart looks the same regardless
/// of the recording rig or where the phone sat.
class CourtDimensions {
  const CourtDimensions._();

  // Regulation (NBA) half-court measurements, in feet, expressed relative to
  // the basket at the origin.
  static const double rimRadius = 0.75; // 9" rim radius
  static const double restrictedRadius = 4.0; // restricted-area arc
  static const double laneHalfWidth = 8.0; // 16' lane → ±8'
  static const double basketToBaseline = 5.25; // rim centre is 5'3" off the baseline
  static const double freeThrowLineY = 13.75; // 15' from backboard − 15" rim inset
  static const double threePointRadius = 23.75; // arc radius from the basket
  static const double cornerThreeX = 22.0; // corner 3 is a straight 22' line
  static const double halfCourtY = 41.75; // baseline→half-court is 47'

  /// Where the straight corner-3 line meets the arc (y, in feet).
  static double get cornerThreeApexY =>
      math.sqrt(threePointRadius * threePointRadius - cornerThreeX * cornerThreeX);
}

/// The canonical shot-chart zones (NBA-style breakdown). One shot maps to
/// exactly one zone via [classifyZone].
enum CourtZone {
  restricted,
  paint,
  midLeft,
  midCenter,
  midRight,
  cornerLeft3,
  cornerRight3,
  wingLeft3,
  wingRight3,
  top3,
}

extension CourtZoneInfo on CourtZone {
  /// Human-readable label for chips / legends.
  String get label => switch (this) {
        CourtZone.restricted => 'Restricted',
        CourtZone.paint => 'Paint',
        CourtZone.midLeft => 'Mid Left',
        CourtZone.midCenter => 'Mid Center',
        CourtZone.midRight => 'Mid Right',
        CourtZone.cornerLeft3 => 'Left Corner 3',
        CourtZone.cornerRight3 => 'Right Corner 3',
        CourtZone.wingLeft3 => 'Left Wing 3',
        CourtZone.wingRight3 => 'Right Wing 3',
        CourtZone.top3 => 'Top 3',
      };

  /// Whether a make in this zone is worth three points.
  bool get isThree => switch (this) {
        CourtZone.cornerLeft3 ||
        CourtZone.cornerRight3 ||
        CourtZone.wingLeft3 ||
        CourtZone.wingRight3 ||
        CourtZone.top3 =>
          true,
        _ => false,
      };

  /// Stable key for persistence.
  String get storageKey => name;

  static CourtZone? fromStorageKey(String? key) {
    if (key == null) return null;
    for (final z in CourtZone.values) {
      if (z.name == key) return z;
    }
    return null;
  }
}

/// Classify a court position (feet, origin at the basket) into a [CourtZone].
///
/// The order of tests matters: restricted-area first, then three-point (corner
/// lines + arc), then paint, then the mid-range fan. Angles are measured from
/// straight-on (`atan2(x, y)`): 0° is dead centre, positive is to the right.
CourtZone classifyZone(Offset courtFeet) {
  final x = courtFeet.dx;
  final y = courtFeet.dy;
  final r = math.sqrt(x * x + y * y);

  if (r <= CourtDimensions.restrictedRadius) return CourtZone.restricted;

  // Three-point: a straight corner line, or beyond the arc.
  final isCorner = x.abs() >= CourtDimensions.cornerThreeX &&
      y <= CourtDimensions.cornerThreeApexY;
  final isArc = r >= CourtDimensions.threePointRadius;
  if (isCorner || isArc) {
    if (isCorner) {
      return x < 0 ? CourtZone.cornerLeft3 : CourtZone.cornerRight3;
    }
    final deg = _degrees(math.atan2(x, y));
    if (deg.abs() <= 18) return CourtZone.top3;
    return deg < 0 ? CourtZone.wingLeft3 : CourtZone.wingRight3;
  }

  // Inside the lane (and out of the restricted area) → paint.
  if (x.abs() <= CourtDimensions.laneHalfWidth &&
      y <= CourtDimensions.freeThrowLineY) {
    return CourtZone.paint;
  }

  // Everything else is a mid-range two, split into a left / centre / right fan.
  final deg = _degrees(math.atan2(x, y));
  if (deg.abs() <= 20) return CourtZone.midCenter;
  return deg < 0 ? CourtZone.midLeft : CourtZone.midRight;
}

double _degrees(double radians) => radians * 180 / math.pi;

/// Converts court coordinates (feet, origin at the basket) to and from a
/// normalized `[0,1]²` box used by the shot-map painter. The basket sits near
/// the top-centre and the court extends downward, matching how a broadcast
/// half-court graphic is drawn.
class CourtRenderMetrics {
  const CourtRenderMetrics._();

  static const double _minX = -CourtDimensions.laneHalfWidth * 3.125; // ±25'
  static const double _maxX = CourtDimensions.laneHalfWidth * 3.125;
  static const double _minY = -CourtDimensions.basketToBaseline; // baseline
  static const double _maxY = CourtDimensions.halfCourtY; // half court

  static const double worldWidth = _maxX - _minX; // 50'
  static const double worldHeight = _maxY - _minY; // 47'

  /// Aspect ratio (width / height) of the rendered half court.
  static double get aspectRatio => worldWidth / worldHeight;

  /// Court feet → normalized `[0,1]` point (y grows downward on screen).
  static Offset normalize(Offset courtFeet) => Offset(
        (courtFeet.dx - _minX) / worldWidth,
        (courtFeet.dy - _minY) / worldHeight,
      );

  /// Normalized `[0,1]` point → court feet (inverse of [normalize]).
  static Offset denormalize(Offset norm) => Offset(
        _minX + norm.dx * worldWidth,
        _minY + norm.dy * worldHeight,
      );
}
