import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/utils/trajectory_prediction.dart';

BoundingBox _box(double cx, double cy, double w, double h) => BoundingBox(
      x1: cx - w / 2,
      y1: cy - h / 2,
      x2: cx + w / 2,
      y2: cy + h / 2,
    );

FrameData _frameWith(List<Detection> detections) =>
    FrameData(frameNumber: 0, timestamp: 0, detections: detections);

Detection _det(String label, double cx, double cy) => Detection(
      trackId: 0,
      bbox: _box(cx, cy, 20, 20),
      confidence: 0.9,
      timestamp: 0,
      label: label,
    );

void main() {
  group('calculateShotAccuracyFromRimCrossing', () {
    // Hoop centered at (100,100); rim plane (bbox top) at y=85.
    final hoop = const Offset(100, 100);
    final hoopBBox = _box(100, 100, 60, 30); // width 60 -> radius 30

    test('a clean drop through center scores ~100%', () {
      final ball = <Offset>[
        const Offset(100, 40),
        const Offset(100, 60),
        const Offset(100, 80),
        const Offset(100, 120),
      ];
      final result = TrajectoryPredictor.calculateShotAccuracyFromRimCrossing(
        ballPoints: ball,
        hoopPosition: hoop,
        hoopBBox: hoopBBox,
        hoopRadius: 30,
      );
      expect(result.accuracy, greaterThan(90));
      expect(result.confidence, isNot(ShotConfidence.insufficient));
    });

    test('a crossing far off-center scores low', () {
      final ball = <Offset>[
        const Offset(200, 40),
        const Offset(200, 60),
        const Offset(200, 80),
        const Offset(200, 120),
      ];
      final result = TrajectoryPredictor.calculateShotAccuracyFromRimCrossing(
        ballPoints: ball,
        hoopPosition: hoop,
        hoopBBox: hoopBBox,
        hoopRadius: 30,
      );
      expect(result.accuracy, lessThan(20));
    });

    test('insufficient points is reported, not crashed', () {
      final result = TrajectoryPredictor.calculateShotAccuracyFromRimCrossing(
        ballPoints: const [Offset(100, 100)],
        hoopPosition: hoop,
        hoopBBox: hoopBBox,
        hoopRadius: 30,
      );
      expect(result.confidence, ShotConfidence.insufficient);
    });
  });

  group('checkMadeDetection', () {
    final hoop = const Offset(100, 100);

    test('a "made" label near the hoop returns a high-confidence make', () {
      final frames = [
        _frameWith([_det('made', 110, 105)]),
      ];
      final result = TrajectoryPredictor.checkMadeDetection(frames, hoop);
      expect(result, isNotNull);
      expect(result!.accuracy, greaterThan(50));
      expect(result.confidence, ShotConfidence.high);
    });

    test('a "made" label far from the hoop is ignored', () {
      final frames = [
        _frameWith([_det('made', 900, 900)]),
      ];
      expect(TrajectoryPredictor.checkMadeDetection(frames, hoop), isNull);
    });

    test('no "made" label returns null', () {
      final frames = [
        _frameWith([_det('ball', 100, 100), _det('rim', 100, 100)]),
      ];
      expect(TrajectoryPredictor.checkMadeDetection(frames, hoop), isNull);
    });
  });

  group('willShotGoIn', () {
    test('does not mutate the caller\'s ball-point list', () {
      final ball = <Offset>[
        const Offset(100, 40),
        const Offset(100, 60),
        const Offset(100, 80),
        const Offset(100, 120),
      ];
      final before = ball.length;
      TrajectoryPredictor.willShotGoIn(
        ballPoints: ball,
        hoopPosition: const Offset(100, 100),
        hoopRadius: 30,
      );
      expect(ball.length, before,
          reason: 'input list must be treated as read-only');
    });
  });
}
