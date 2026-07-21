import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:hooplab/utils/shooting_form_analyzer.dart';

// ---- builders -------------------------------------------------------------

PoseLandmark _lm(
  PoseLandmarkType t,
  List<double> xyz, [
  double likelihood = 0.95,
]) =>
    PoseLandmark(
      type: t,
      x: xyz[0],
      y: xyz[1],
      z: xyz.length > 2 ? xyz[2] : 0,
      likelihood: likelihood,
    );

/// A right-side shooter pose. Coordinates are [x, y, z]; smaller y = higher on
/// screen (image convention), matching the app's frame space.
Pose _pose({
  required List<double> shoulder,
  required List<double> elbow,
  required List<double> wrist,
  List<double>? hip,
  List<double>? knee,
  List<double>? ankle,
  double likelihood = 0.95,
}) {
  final m = <PoseLandmarkType, PoseLandmark>{
    PoseLandmarkType.rightShoulder:
        _lm(PoseLandmarkType.rightShoulder, shoulder, likelihood),
    PoseLandmarkType.rightElbow: _lm(PoseLandmarkType.rightElbow, elbow, likelihood),
    PoseLandmarkType.rightWrist: _lm(PoseLandmarkType.rightWrist, wrist, likelihood),
  };
  if (hip != null) {
    m[PoseLandmarkType.rightHip] = _lm(PoseLandmarkType.rightHip, hip, likelihood);
  }
  if (knee != null) {
    m[PoseLandmarkType.rightKnee] = _lm(PoseLandmarkType.rightKnee, knee, likelihood);
  }
  if (ankle != null) {
    m[PoseLandmarkType.rightAnkle] =
        _lm(PoseLandmarkType.rightAnkle, ankle, likelihood);
  }
  return Pose(landmarks: m);
}

// ---- reusable joint configurations ----------------------------------------

// Set point ("pocket"): shooting elbow bent to 90°, hand low. In-plane (z=0).
const _setInPlane = {
  'shoulder': [200.0, 200.0, 0.0],
  'elbow': [200.0, 260.0, 0.0],
  'wrist': [260.0, 260.0, 0.0],
};

// The SAME 90° set point, but the forearm/upper-arm are rotated into depth so
// the arm points partly toward the camera. Its raw 2D projection reads ~143°;
// only a depth-aware (3D) measurement recovers the true 90°. This is the
// "same arm angle looks different from a different court spot" case.
const _setForeshortened = {
  'shoulder': [160.0, 180.0, 80.0],
  'elbow': [200.0, 260.0, 0.0],
  'wrist': [280.0, 300.0, 80.0],
};

// Collapsed set point: elbow only ~60°.
const _setTooTight = {
  'shoulder': [200.0, 200.0, 0.0],
  'elbow': [200.0, 260.0, 0.0],
  'wrist': [252.0, 230.0, 0.0],
};

// Release / follow-through: arm near full extension (~177°), hand high.
const _release = {
  'shoulder': [200.0, 200.0, 0.0],
  'elbow': [200.0, 150.0, 0.0],
  'wrist': [205.0, 60.0, 0.0],
};

// Release opened to ~145° — meets the ~142°+ optimum.
const _release145 = {
  'shoulder': [200.0, 200.0, 0.0],
  'elbow': [200.0, 150.0, 0.0],
  'wrist': [252.0, 76.0, 0.0],
};

// Release cut short at ~125° — below the target.
const _release125 = {
  'shoulder': [200.0, 200.0, 0.0],
  'elbow': [200.0, 150.0, 0.0],
  'wrist': [270.0, 100.0, 0.0],
};

// Deep, powered knee load (~118°).
const _kneeGood = {
  'hip': [140.0, 300.0, 0.0],
  'knee': [200.0, 400.0, 0.0],
  'ankle': [140.0, 500.0, 0.0],
};

// Barely-bent, near-straight legs (~180°).
const _kneeStraight = {
  'hip': [200.0, 300.0, 0.0],
  'knee': [200.0, 400.0, 0.0],
  'ankle': [200.0, 500.0, 0.0],
};

Pose _frame(Map<String, List<double>> arm, Map<String, List<double>>? legs) =>
    _pose(
      shoulder: arm['shoulder']!,
      elbow: arm['elbow']!,
      wrist: arm['wrist']!,
      hip: legs?['hip'],
      knee: legs?['knee'],
      ankle: legs?['ankle'],
    );

/// Four set-point frames followed by three release frames — a minimal shot.
List<Pose> _shot(
  Map<String, List<double>> setArm, {
  Map<String, List<double>>? legs,
  Map<String, List<double>> releaseArm = _release,
}) =>
    [
      for (var i = 0; i < 4; i++) _frame(setArm, legs),
      for (var i = 0; i < 3; i++) _frame(releaseArm, legs),
    ];

void main() {
  group('ShootingFormAnalyzer', () {
    test('empty input yields no data', () {
      final a = ShootingFormAnalyzer.analyze(const []);
      expect(a.hasData, isFalse);
      expect(a.cues, isEmpty);
    });

    test('finds the set point, release extension and knee bend', () {
      final a = ShootingFormAnalyzer.analyze(_shot(_setInPlane, legs: _kneeGood));

      expect(a.hasData, isTrue);
      expect(a.setElbowAngle, closeTo(90, 2));
      expect(a.releaseElbowAngle, greaterThanOrEqualTo(142));
      expect(a.kneeBendAngle, closeTo(118, 3));
      // Clean mechanics → high posture score, a single positive note.
      expect(a.postureScore, greaterThan(90));
      expect(a.feedback.toLowerCase(), contains('solid'));
    });

    test('a textbook set point reads the same from a foreshortened angle', () {
      // Same true 90° elbow, two different camera-relative orientations.
      final inPlane =
          ShootingFormAnalyzer.analyze(_shot(_setInPlane, legs: _kneeGood));
      final foreshortened =
          ShootingFormAnalyzer.analyze(_shot(_setForeshortened, legs: _kneeGood));

      // Both recover ~90° despite the second arm projecting to ~143° in 2D.
      expect(inPlane.setElbowAngle, closeTo(90, 3));
      expect(foreshortened.setElbowAngle, closeTo(90, 3));
      // The perspective-distorted 2D reading (~143°) is NOT what we report.
      expect(foreshortened.setElbowAngle, lessThan(110));
      expect(foreshortened.usedDepth, isTrue);
      // Neither should be told their set point is wrong.
      expect(inPlane.feedback, isNot(contains('too tight')));
      expect(foreshortened.feedback, isNot(contains('too tight')));
    });

    test('falls back to 2D when depth is untrustworthy', () {
      // Low likelihood on the foreshortened arm → depth ignored, so the 2D
      // reading (~143°) surfaces and the set point looks (wrongly) open.
      final lowConf = [
        for (var i = 0; i < 4; i++)
          _pose(
            shoulder: _setForeshortened['shoulder']!,
            elbow: _setForeshortened['elbow']!,
            wrist: _setForeshortened['wrist']!,
            hip: _kneeGood['hip'],
            knee: _kneeGood['knee'],
            ankle: _kneeGood['ankle'],
            likelihood: 0.35,
          ),
        for (var i = 0; i < 3; i++)
          _pose(
            shoulder: _release['shoulder']!,
            elbow: _release['elbow']!,
            wrist: _release['wrist']!,
            likelihood: 0.35,
          ),
      ];
      final a = ShootingFormAnalyzer.analyze(lowConf);
      expect(a.usedDepth, isFalse);
      expect(a.setElbowAngle, greaterThan(120));
    });

    test('a ~145° release meets the ~142°+ extension optimum', () {
      final a = ShootingFormAnalyzer.analyze(
        _shot(_setInPlane, releaseArm: _release145, legs: _kneeGood),
      );
      expect(a.releaseElbowAngle, closeTo(145, 3));
      expect(a.feedback, isNot(contains('Finish taller')));
      expect(a.feedback, contains('good extension'));
    });

    test('flags a release cut short below the ~142° target', () {
      final a = ShootingFormAnalyzer.analyze(
        _shot(_setInPlane, releaseArm: _release125, legs: _kneeGood),
      );
      expect(a.releaseElbowAngle, closeTo(125, 3));
      expect(a.feedback, contains('Finish taller'));
      expect(a.feedback, contains('142'));
    });

    test('asks for more knee bend when the legs stay straight', () {
      final a =
          ShootingFormAnalyzer.analyze(_shot(_setInPlane, legs: _kneeStraight));

      expect(a.kneeBendAngle, greaterThan(145));
      expect(a.feedback, contains('Bend your knees more'));
    });

    test('flags a collapsed set point with a target angle', () {
      final a = ShootingFormAnalyzer.analyze(_shot(_setTooTight, legs: _kneeGood));

      expect(a.setElbowAngle, closeTo(60, 3));
      expect(a.feedback, contains('Set point too tight'));
      expect(a.feedback, contains('90'));
    });

    test('skips knee feedback when legs are not visible', () {
      final a = ShootingFormAnalyzer.analyze(_shot(_setInPlane));
      expect(a.kneeBendAngle, isNull);
      expect(a.feedback, isNot(contains('knee')));
      // Still scores the arm.
      expect(a.setElbowAngle, closeTo(90, 2));
      expect(a.postureScore, isNotNull);
    });
  });
}
