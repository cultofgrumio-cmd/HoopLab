import 'dart:math';

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Analyzes a shooter's body mechanics (arm angles + knee bend) from a sequence
/// of ML Kit pose frames and produces specific, coach-style form cues.
///
/// ## Why this measures angles in 3D
///
/// The same real-world joint angle projects to a *different* 2D angle depending
/// on where the shooter stands relative to the camera. A forearm pointing partly
/// toward or away from the lens is foreshortened, so a textbook 90° set-point can
/// read as anything from ~60° to ~110° in the raw pixels — purely because the
/// player moved to a different spot on the court, not because their form changed.
///
/// To correct for this, joint angles are computed from the **3D** landmark
/// vectors `(x, y, z)`, where `z` is ML Kit's depth estimate (origin at the hip
/// midpoint, roughly the same scale as `x`). The 3D angle reconstructs the actual
/// limb configuration and is largely invariant to the shooter's court position.
/// When depth is untrustworthy for a joint (low landmark likelihood) we fall back
/// to the raw 2D angle, and every keyframe angle is a median over a small window
/// of frames so single-frame jitter (from either projection or noisy depth) does
/// not drive the feedback.
class ShootingFormAnalyzer {
  // ---- Ideal shooting-form reference values (degrees) -----------------------

  /// Shooting-elbow angle at the set point ("the pocket"): forearm vertical
  /// under the ball, forming an "L". Coaching target ≈ 90°.
  static const double setElbowIdealLow = 82;
  static const double setElbowIdealHigh = 98;

  /// Below this the set point is collapsed/too tight; above it the elbow is
  /// opening (pushing) before the legs drive the ball up.
  static const double setElbowTooTight = 78;
  static const double setElbowTooOpen = 108;

  /// Elbow extension at release/follow-through. The shooting arm should open up
  /// to about 142°+ as it drives toward the rim; below [releaseElbowUnder] the
  /// finish is cut short.
  static const double releaseElbowFull = 142;
  static const double releaseElbowUnder = 135;

  /// Deepest knee flexion in the load/dip. A good shooting dip loads to
  /// ~110–130° (lower = deeper). Above [kneeBendShallow] the shooter is barely
  /// bending — the classic "all arms, no legs" shot.
  static const double kneeBendIdealLow = 110;
  static const double kneeBendIdealHigh = 130;
  static const double kneeBendSlightlyShallow = 135;
  static const double kneeBendShallow = 145;

  /// Landmark likelihood at/above which we trust the depth channel for that
  /// joint's 3D angle.
  static const double _depthTrustLikelihood = 0.5;

  /// Minimum likelihood for a landmark to be used at all.
  static const double _minLikelihood = 0.3;

  /// Half-width (in frames) of the median smoothing window around a keyframe.
  static const int _smoothWindow = 2;

  /// Analyze [poses] (one shooter pose per processed frame, in temporal order)
  /// and return structured form metrics + ordered coaching cues.
  static ShootingFormAnalysis analyze(List<Pose> poses) {
    if (poses.isEmpty) return ShootingFormAnalysis.empty();

    final side = _shootingSide(poses);
    if (side == null) return ShootingFormAnalysis.empty();

    final shoulder = side == _Side.right
        ? PoseLandmarkType.rightShoulder
        : PoseLandmarkType.leftShoulder;
    final elbow = side == _Side.right
        ? PoseLandmarkType.rightElbow
        : PoseLandmarkType.leftElbow;
    final wrist = side == _Side.right
        ? PoseLandmarkType.rightWrist
        : PoseLandmarkType.leftWrist;

    // Per-frame metrics (null where the needed landmarks are missing).
    final elbowAngles = <double?>[];
    final wristRaise = <double?>[]; // shoulder.y - wrist.y  (>0 = wrist up)
    final kneeAngles = <double?>[];
    bool usedDepth = false;

    for (final pose in poses) {
      final s = _lm(pose, shoulder);
      final e = _lm(pose, elbow);
      final w = _lm(pose, wrist);

      if (s != null && e != null && w != null) {
        final m = _jointAngle(s, e, w);
        elbowAngles.add(m.angle);
        usedDepth |= m.usedDepth;
      } else {
        elbowAngles.add(null);
      }

      wristRaise.add((s != null && w != null) ? s.y - w.y : null);

      final knee = _kneeAngle(pose);
      if (knee != null) {
        kneeAngles.add(knee.angle);
        usedDepth |= knee.usedDepth;
      } else {
        kneeAngles.add(null);
      }
    }

    // Release / follow-through = the frame where the shooting hand is highest.
    final releaseIdx = _argExtreme(wristRaise, max: true);

    // Set point ("the pocket") = the most-flexed shooting elbow before release,
    // i.e. the deepest load just prior to driving the ball up.
    final int setSearchEnd = releaseIdx ?? (elbowAngles.length - 1);
    final setIdx = _argExtreme(
      elbowAngles,
      max: false,
      start: 0,
      end: setSearchEnd,
    );

    // Deepest knee bend = the minimum knee angle anywhere in the sequence.
    final kneeIdx = _argExtreme(kneeAngles, max: false);

    final setElbow = setIdx == null ? null : _median(elbowAngles, setIdx);
    final releaseElbow =
        releaseIdx == null ? null : _median(elbowAngles, releaseIdx);
    final kneeBend = kneeIdx == null ? null : _median(kneeAngles, kneeIdx);

    final cues = <String>[];
    final scoreParts = <double>[]; // each 0..1
    final scoreWeights = <double>[];

    // ---- Knee bend (surfaced first — legs are the engine of the shot) -------
    if (kneeBend != null) {
      scoreWeights.add(0.30);
      scoreParts.add(_bandScore(
        kneeBend,
        idealLow: kneeBendIdealLow,
        idealHigh: kneeBendIdealHigh,
        falloff: 40,
      ));
      final k = kneeBend.round();
      if (kneeBend > kneeBendShallow) {
        cues.add(
          'Bend your knees more — you only dipped to ~$k°. Load down to about '
          '115–125° so your legs, not your arms, power the shot.',
        );
      } else if (kneeBend > kneeBendSlightlyShallow) {
        cues.add(
          'Add a little more knee bend — dip toward ~120° (you reached ~$k°) '
          'to get your legs into the shot.',
        );
      }
    }

    // ---- Set-point elbow angle ----------------------------------------------
    if (setElbow != null) {
      scoreWeights.add(0.40);
      scoreParts.add(_bandScore(
        setElbow,
        idealLow: setElbowIdealLow,
        idealHigh: setElbowIdealHigh,
        falloff: 32,
      ));
      final a = setElbow.round();
      if (setElbow < setElbowTooTight) {
        cues.add(
          'Set point too tight — shooting elbow ~$a°. Load with the elbow bent '
          'to about 90° (forearm vertical, tucked under the ball) so you lift '
          'the shot instead of slinging it.',
        );
      } else if (setElbow > setElbowTooOpen) {
        cues.add(
          'Elbow opening too early — ~$a° at your set point. Start near 90° '
          'with the elbow under the ball, then drive up through it.',
        );
      }
    }

    // ---- Release extension --------------------------------------------------
    if (releaseElbow != null) {
      scoreWeights.add(0.30);
      scoreParts.add(_bandScore(
        releaseElbow,
        idealLow: releaseElbowFull,
        idealHigh: 185,
        falloff: 45,
      ));
      final r = releaseElbow.round();
      if (releaseElbow < releaseElbowUnder) {
        cues.add(
          'Finish taller — your shooting arm only reached ~$r° at release. '
          'Extend it to about 142°+ and follow through reaching into the rim.',
        );
      }
    }

    // Positive note when the mechanics we could measure all look clean.
    if (cues.isEmpty && (setElbow != null || kneeBend != null)) {
      final bits = <String>[];
      if (setElbow != null) bits.add('~${setElbow.round()}° set');
      if (releaseElbow != null && releaseElbow >= releaseElbowUnder) {
        bits.add('good extension');
      }
      if (kneeBend != null && kneeBend <= kneeBendSlightlyShallow) {
        bits.add('good knee load (~${kneeBend.round()}°)');
      }
      cues.add('Solid mechanics — ${bits.join(', ')}.');
    }

    double? postureScore;
    if (scoreParts.isNotEmpty) {
      final totalWeight = scoreWeights.reduce((a, b) => a + b);
      double acc = 0;
      for (var i = 0; i < scoreParts.length; i++) {
        acc += scoreParts[i] * scoreWeights[i];
      }
      postureScore = (acc / totalWeight) * 100;
    }

    return ShootingFormAnalysis(
      setElbowAngle: setElbow,
      releaseElbowAngle: releaseElbow,
      kneeBendAngle: kneeBend,
      postureScore: postureScore,
      usedDepth: usedDepth,
      cues: cues,
    );
  }

  // ---- Shooting-side selection ---------------------------------------------

  /// The arm that rises highest above its shoulder across the sequence is taken
  /// as the shooting arm. Ties (and one-sided visibility) resolve to whichever
  /// side has usable landmarks.
  static _Side? _shootingSide(List<Pose> poses) {
    double rightRaise = double.negativeInfinity;
    double leftRaise = double.negativeInfinity;

    for (final pose in poses) {
      final rs = _lm(pose, PoseLandmarkType.rightShoulder);
      final rw = _lm(pose, PoseLandmarkType.rightWrist);
      if (rs != null && rw != null) {
        rightRaise = max(rightRaise, rs.y - rw.y);
      }
      final ls = _lm(pose, PoseLandmarkType.leftShoulder);
      final lw = _lm(pose, PoseLandmarkType.leftWrist);
      if (ls != null && lw != null) {
        leftRaise = max(leftRaise, ls.y - lw.y);
      }
    }

    if (rightRaise == double.negativeInfinity &&
        leftRaise == double.negativeInfinity) {
      return null;
    }
    return rightRaise >= leftRaise ? _Side.right : _Side.left;
  }

  // ---- Angle helpers --------------------------------------------------------

  /// Knee angle (hip-knee-ankle) for the most-loaded visible leg. Uses both
  /// legs when available (averaged) so a partly-occluded leg doesn't dominate.
  static _AngleSample? _kneeAngle(Pose pose) {
    final samples = <_AngleSample>[];
    for (final legs in const [
      [
        PoseLandmarkType.rightHip,
        PoseLandmarkType.rightKnee,
        PoseLandmarkType.rightAnkle,
      ],
      [
        PoseLandmarkType.leftHip,
        PoseLandmarkType.leftKnee,
        PoseLandmarkType.leftAnkle,
      ],
    ]) {
      final hip = _lm(pose, legs[0]);
      final knee = _lm(pose, legs[1]);
      final ankle = _lm(pose, legs[2]);
      if (hip != null && knee != null && ankle != null) {
        samples.add(_jointAngle(hip, knee, ankle));
      }
    }
    if (samples.isEmpty) return null;
    final avg =
        samples.map((s) => s.angle).reduce((a, b) => a + b) / samples.length;
    return _AngleSample(avg, samples.every((s) => s.usedDepth));
  }

  /// Perspective-corrected angle at [b] formed by [a]-[b]-[c]. Uses the 3D
  /// vectors when all three landmarks have trustworthy depth, otherwise the raw
  /// 2D angle (see class doc).
  static _AngleSample _jointAngle(
    PoseLandmark a,
    PoseLandmark b,
    PoseLandmark c,
  ) {
    final depthOk = a.likelihood >= _depthTrustLikelihood &&
        b.likelihood >= _depthTrustLikelihood &&
        c.likelihood >= _depthTrustLikelihood;
    if (depthOk) {
      return _AngleSample(
        _angleBetween(
          a.x - b.x, a.y - b.y, a.z - b.z, //
          c.x - b.x, c.y - b.y, c.z - b.z,
        ),
        true,
      );
    }
    return _AngleSample(
      _angleBetween(
        a.x - b.x, a.y - b.y, 0, //
        c.x - b.x, c.y - b.y, 0,
      ),
      false,
    );
  }

  /// Angle (degrees) between two 3D vectors.
  static double _angleBetween(
    double ax,
    double ay,
    double az,
    double bx,
    double by,
    double bz,
  ) {
    final dot = ax * bx + ay * by + az * bz;
    final magA = sqrt(ax * ax + ay * ay + az * az);
    final magB = sqrt(bx * bx + by * by + bz * bz);
    if (magA == 0 || magB == 0) return 0;
    final cos = (dot / (magA * magB)).clamp(-1.0, 1.0);
    return acos(cos) * 180 / pi;
  }

  // ---- Sequence utilities ---------------------------------------------------

  static PoseLandmark? _lm(Pose pose, PoseLandmarkType type) {
    final l = pose.landmarks[type];
    if (l == null || l.likelihood < _minLikelihood) return null;
    return l;
  }

  /// Index of the max/min non-null value in [values] within `[start, end]`
  /// (inclusive). Returns null when the range has no data.
  static int? _argExtreme(
    List<double?> values, {
    required bool max,
    int start = 0,
    int? end,
  }) {
    final last = end ?? values.length - 1;
    int? bestIdx;
    double? best;
    for (var i = start; i <= last && i < values.length; i++) {
      final v = values[i];
      if (v == null) continue;
      if (best == null || (max ? v > best : v < best)) {
        best = v;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// Median of the non-null values within ±[_smoothWindow] frames of [center].
  static double? _median(List<double?> values, int center) {
    final window = <double>[];
    for (var i = center - _smoothWindow; i <= center + _smoothWindow; i++) {
      if (i < 0 || i >= values.length) continue;
      final v = values[i];
      if (v != null) window.add(v);
    }
    if (window.isEmpty) return null;
    window.sort();
    final mid = window.length ~/ 2;
    return window.length.isOdd
        ? window[mid]
        : (window[mid - 1] + window[mid]) / 2;
  }

  /// 1.0 inside `[idealLow, idealHigh]`, falling linearly to 0 over [falloff]
  /// degrees on either side.
  static double _bandScore(
    double value, {
    required double idealLow,
    required double idealHigh,
    required double falloff,
  }) {
    if (value >= idealLow && value <= idealHigh) return 1.0;
    final dev = value < idealLow ? idealLow - value : value - idealHigh;
    return (1.0 - dev / falloff).clamp(0.0, 1.0);
  }
}

enum _Side { left, right }

class _AngleSample {
  final double angle;
  final bool usedDepth;
  const _AngleSample(this.angle, this.usedDepth);
}

/// Structured result of [ShootingFormAnalyzer.analyze].
class ShootingFormAnalysis {
  /// Shooting-elbow angle (°) at the set point, or null if not measurable.
  final double? setElbowAngle;

  /// Shooting-elbow angle (°) at release/follow-through.
  final double? releaseElbowAngle;

  /// Deepest knee-flexion angle (°) during the load, or null if legs weren't
  /// visible.
  final double? kneeBendAngle;

  /// Body-mechanics score (0–100) over whatever joints were measurable, or null
  /// when no pose data was usable.
  final double? postureScore;

  /// True when the perspective-correcting depth channel drove at least one
  /// measured angle (vs. a pure 2D fallback).
  final bool usedDepth;

  /// Ordered, specific coaching cues (most impactful first). Empty when there
  /// was nothing to say (or nothing measurable).
  final List<String> cues;

  const ShootingFormAnalysis({
    required this.setElbowAngle,
    required this.releaseElbowAngle,
    required this.kneeBendAngle,
    required this.postureScore,
    required this.usedDepth,
    required this.cues,
  });

  factory ShootingFormAnalysis.empty() => const ShootingFormAnalysis(
        setElbowAngle: null,
        releaseElbowAngle: null,
        kneeBendAngle: null,
        postureScore: null,
        usedDepth: false,
        cues: [],
      );

  /// True when at least one body-mechanics angle was measured.
  bool get hasData => postureScore != null;

  /// Cues joined into a single human-readable string.
  String get feedback => cues.join(' • ');
}
