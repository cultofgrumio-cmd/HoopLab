import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/utils/shot_predictor.dart';
import 'package:hooplab/utils/trajectory_prediction.dart' show ShotConfidence;

/// Sample the launch (release → apex) of a projectile:
///   x(t) = vx·t,  y(t) = y0 + vy·t + 0.5·g·t²   (screen y grows downward)
({List<Offset> pts, List<double> ts}) _launch({
  required double vx,
  required double y0,
  required double vy,
  required double g,
  required double apexT,
  int samples = 6,
}) {
  final pts = <Offset>[];
  final ts = <double>[];
  for (int i = 0; i < samples; i++) {
    final t = apexT * i / (samples - 1);
    pts.add(Offset(vx * t, y0 + vy * t + 0.5 * g * t * t));
    ts.add(t);
  }
  return (pts: pts, ts: ts);
}

void main() {
  // Arc chosen so the full parabola passes through rim (200, 250) on descent:
  //   y(t) = 400 - 500t + 250t²  (apex y=150 at t=1)
  //   reaches y=250 (descending) at t≈1.632; with vx=122.5 → x≈200 there.
  group('ShotPredictor — release prediction', () {
    test('a launch aimed through the rim predicts IN', () {
      final l = _launch(vx: 122.5, y0: 400, vy: -500, g: 500, apexT: 1.0);
      final p = ShotPredictor.predictFromRelease(
        ballPoints: l.pts,
        timestamps: l.ts,
        rimCenter: const Offset(200, 250),
        rimRadius: 30,
      );
      expect(p.isKnown, isTrue);
      expect(p.willMake, isTrue);
      expect(p.accuracy, greaterThan(80));
      expect(p.projectedPoint, isNotNull);
      // Projected point should land essentially on the rim centre.
      expect((p.projectedPoint! - const Offset(200, 250)).distance, lessThan(10));
    });

    test('the same arc thrown too hard (overshoots) predicts OUT', () {
      // Double the horizontal speed → descent crosses the rim level far right.
      final l = _launch(vx: 245, y0: 400, vy: -500, g: 500, apexT: 1.0);
      final p = ShotPredictor.predictFromRelease(
        ballPoints: l.pts,
        timestamps: l.ts,
        rimCenter: const Offset(200, 250),
        rimRadius: 30,
      );
      expect(p.isKnown, isTrue);
      expect(p.willMake, isFalse);
      expect(p.accuracy, lessThan(50));
    });

    test('a clean 6-point launch yields high confidence', () {
      final l = _launch(vx: 122.5, y0: 400, vy: -500, g: 500, apexT: 1.0);
      final p = ShotPredictor.predictFromRelease(
        ballPoints: l.pts,
        timestamps: l.ts,
        rimCenter: const Offset(200, 250),
        rimRadius: 30,
      );
      expect(p.confidence, ShotConfidence.high);
    });

    test('too few points returns unknown', () {
      final p = ShotPredictor.predictFromRelease(
        ballPoints: const [Offset(0, 400), Offset(50, 300)],
        timestamps: const [0.0, 0.2],
        rimCenter: const Offset(200, 250),
        rimRadius: 30,
      );
      expect(p.isKnown, isFalse);
      expect(p.confidence, ShotConfidence.insufficient);
    });
  });
}
