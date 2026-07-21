import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/utils/shot_quality_evaluator.dart';

void main() {
  group('ShotQualityEvaluator', () {
    test('too few points yields a zero score with feedback', () {
      final result = ShotQualityEvaluator.evaluateShotQuality(
        ballTrajectory: const [Offset(0, 0), Offset(1, 1)],
        hoopPosition: const Offset(100, 100),
      );
      expect(result.overallScore, 0);
      expect(result.feedback, isNotEmpty);
    });

    test('a smooth parabolic arc toward the hoop scores above zero', () {
      // Ball rises from (0,300) to a peak then descends to the hoop at (200,100).
      // Screen coords: smaller y = higher.
      final hoop = const Offset(200, 100);
      final trajectory = <Offset>[];
      for (int i = 0; i <= 10; i++) {
        final t = i / 10.0;
        final x = 200 * t;
        // Parabola that arcs up then down; smaller y is higher on screen.
        final y = 300 - 260 * (1 - pow(2 * t - 1, 2)).toDouble();
        trajectory.add(Offset(x, y.clamp(0, 400).toDouble()));
      }
      final result = ShotQualityEvaluator.evaluateShotQuality(
        ballTrajectory: trajectory,
        hoopPosition: hoop,
        hoopRadius: 30,
      );
      expect(result.overallScore, greaterThan(0));
      expect(result.overallScore, lessThanOrEqualTo(100));
      expect(result.feedback, isNotEmpty);
    });
  });
}
