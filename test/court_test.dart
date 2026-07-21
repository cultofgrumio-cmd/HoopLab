import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/models/session.dart';
import 'package:hooplab/utils/court.dart';
import 'package:hooplab/utils/court_calibration.dart';

// ---- builders -------------------------------------------------------------

Detection _det(String label, Offset c, double w, double h) => Detection(
      trackId: 0,
      bbox: BoundingBox(
        x1: c.dx - w / 2,
        y1: c.dy - h / 2,
        x2: c.dx + w / 2,
        y2: c.dy + h / 2,
      ),
      confidence: 0.9,
      timestamp: 0,
      label: label,
    );

Pose _poseWithAnkles(Offset left, Offset right, {double likelihood = 0.95}) =>
    Pose(landmarks: {
      PoseLandmarkType.leftAnkle: PoseLandmark(
          type: PoseLandmarkType.leftAnkle,
          x: left.dx,
          y: left.dy,
          z: 0,
          likelihood: likelihood),
      PoseLandmarkType.rightAnkle: PoseLandmark(
          type: PoseLandmarkType.rightAnkle,
          x: right.dx,
          y: right.dy,
          z: 0,
          likelihood: likelihood),
    });

FrameData _frame({List<Detection>? dets, List<Pose>? poses}) => FrameData(
      frameNumber: 0,
      timestamp: 0,
      detections: dets ?? const [],
      poses: poses,
    );

void main() {
  group('classifyZone', () {
    test('at the rim is the restricted area', () {
      expect(classifyZone(const Offset(0, 0)), CourtZone.restricted);
      expect(classifyZone(const Offset(0, 3)), CourtZone.restricted);
    });

    test('free-throw line is in the paint', () {
      expect(classifyZone(const Offset(0, 13.75)), CourtZone.paint);
      expect(classifyZone(const Offset(4, 9)), CourtZone.paint);
    });

    test('mid-range fans split left / centre / right', () {
      expect(classifyZone(const Offset(0, 19)), CourtZone.midCenter);
      expect(classifyZone(const Offset(13, 13)), CourtZone.midRight);
      expect(classifyZone(const Offset(-13, 13)), CourtZone.midLeft);
    });

    test('corner threes are the straight 22ft lines', () {
      expect(classifyZone(const Offset(23, 3)), CourtZone.cornerRight3);
      expect(classifyZone(const Offset(-23, 3)), CourtZone.cornerLeft3);
    });

    test('above-the-break threes split into wings and top', () {
      expect(classifyZone(const Offset(0, 25)), CourtZone.top3);
      expect(classifyZone(const Offset(24, 10)), CourtZone.wingRight3);
      expect(classifyZone(const Offset(-24, 10)), CourtZone.wingLeft3);
    });

    test('three-point flag is consistent', () {
      expect(CourtZone.top3.isThree, isTrue);
      expect(CourtZone.cornerLeft3.isThree, isTrue);
      expect(CourtZone.paint.isThree, isFalse);
      expect(CourtZone.midRight.isThree, isFalse);
    });
  });

  group('CourtCalibration – free throw (Tier 1)', () {
    test('anchors map to their known court points', () {
      final cal = CourtCalibration.fromFreeThrow(
        freeThrowFootAnchor: const Offset(500, 400),
        rimCenter: const Offset(500, 100),
      );
      final ft = cal.locate(const Offset(500, 400))!;
      expect(ft.courtFeet.dx, closeTo(0, 1e-6));
      expect(ft.courtFeet.dy, closeTo(13.75, 1e-6));
      expect(ft.zone, CourtZone.paint);

      final rim = cal.locate(const Offset(500, 100))!;
      expect(rim.courtFeet.dx, closeTo(0, 1e-6));
      expect(rim.courtFeet.dy, closeTo(0, 1e-6));
      expect(rim.zone, CourtZone.restricted);
    });

    test('screen-right maps to court-right (+x)', () {
      final cal = CourtCalibration.fromFreeThrow(
        freeThrowFootAnchor: const Offset(500, 400),
        rimCenter: const Offset(500, 100),
      );
      final loc = cal.locate(const Offset(800, 400))!;
      expect(loc.courtFeet.dx, greaterThan(0));
      expect(loc.zone, CourtZone.midRight);
    });

    test('handles a rotated (diagonal) camera axis', () {
      // Rim→FT axis is (300,400), length 500px = 13.75ft.
      final cal = CourtCalibration.fromFreeThrow(
        freeThrowFootAnchor: const Offset(400, 500),
        rimCenter: const Offset(100, 100),
      );
      final ft = cal.locate(const Offset(400, 500))!;
      expect(ft.courtFeet.dx, closeTo(0, 1e-6));
      expect(ft.courtFeet.dy, closeTo(13.75, 1e-6));
    });
  });

  group('CourtCalibration – uncalibrated (Tier 0)', () {
    test('rim-relative uses the rim width as a scale reference', () {
      // 60px rim = 1.5ft → 0.025 ft/px. Foot 800px below the rim → 20ft out.
      final loc = CourtCalibration.none.locate(
        const Offset(500, 900),
        rimCenter: const Offset(500, 100),
        rimWidth: 60,
      )!;
      expect(loc.courtFeet.dx, closeTo(0, 1e-6));
      expect(loc.courtFeet.dy, closeTo(20, 1e-6));
      expect(loc.zone, CourtZone.midCenter);
    });

    test('returns null without a rim to anchor to', () {
      expect(CourtCalibration.none.locate(const Offset(1, 2)), isNull);
    });
  });

  group('FootAnchorEstimator', () {
    test('prefers the midpoint of the shooter\'s ankles', () {
      final frames = [
        _frame(poses: [_poseWithAnkles(const Offset(100, 900), const Offset(140, 900))]),
      ];
      expect(FootAnchorEstimator.estimate(frames), const Offset(120, 900));
    });

    test('falls back to the person box bottom-centre', () {
      final frames = [
        _frame(dets: [_det('person', const Offset(200, 500), 80, 200)]),
      ];
      // bbox bottom = 500 + 100 = 600, centre x = 200.
      expect(FootAnchorEstimator.estimate(frames), const Offset(200, 600));
    });

    test('falls back to the ball release dropped by a body height', () {
      final frames = [
        _frame(dets: [_det('ball', const Offset(300, 200), 24, 24)]),
      ];
      final anchor = FootAnchorEstimator.estimate(frames, rimWidth: 60);
      expect(anchor!.dx, 300);
      expect(anchor.dy, 200 + 60 * 3.5);
    });

    test('ignores low-likelihood landmarks', () {
      final frames = [
        _frame(
          poses: [
            _poseWithAnkles(const Offset(100, 900), const Offset(140, 900),
                likelihood: 0.1)
          ],
          dets: [_det('person', const Offset(200, 500), 80, 200)],
        ),
      ];
      // Ankles too weak → person box wins.
      expect(FootAnchorEstimator.estimate(frames), const Offset(200, 600));
    });

    test('returns null with nothing to go on', () {
      expect(FootAnchorEstimator.estimate([_frame()]), isNull);
    });
  });

  group('serialization', () {
    test('CourtCalibration round-trips through JSON', () {
      final cal = CourtCalibration.fromFreeThrow(
        freeThrowFootAnchor: const Offset(500, 400),
        rimCenter: const Offset(500, 100),
      );
      final back = CourtCalibration.fromJson(cal.toJson());
      expect(back.tier, CalibrationTier.freeThrow);
      expect(back.rimPixel, const Offset(500, 100));
      expect(back.freeThrowPixel, const Offset(500, 400));
    });

    test('SavedShot preserves location fields', () {
      const shot = SavedShot(
        id: 1,
        startTime: 0,
        endTime: 1,
        prediction: 'MAKE',
        ballTrajectory: [],
        footAnchor: Offset(120, 900),
        courtPosition: Offset(-3, 20),
        zone: 'midLeft',
        rimWidth: 60,
      );
      final back = SavedShot.fromJson(shot.toJson());
      expect(back.footAnchor, const Offset(120, 900));
      expect(back.courtPosition, const Offset(-3, 20));
      expect(back.courtZone, CourtZone.midLeft);
      expect(back.rimWidth, 60);
    });
  });

  group('Session.zoneStats', () {
    SavedShot shot(int id, String zone, bool make) => SavedShot(
          id: id,
          startTime: 0,
          endTime: 1,
          prediction: make ? 'MAKE' : 'MISS',
          ballTrajectory: const [],
          courtPosition: const Offset(0, 20),
          zone: zone,
        );

    test('aggregates makes / attempts per zone over located shots', () {
      final session = Session(
        id: 's',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        videoPath: '',
        name: 'test',
        shots: [
          shot(0, 'top3', true),
          shot(1, 'top3', false),
          shot(2, 'top3', true),
          shot(3, 'paint', true),
          // Unlocated shot is excluded from zone stats.
          const SavedShot(
              id: 4, startTime: 0, endTime: 1, prediction: 'MAKE', ballTrajectory: []),
        ],
      );
      final stats = session.zoneStats;
      expect(stats[CourtZone.top3]!.attempts, 3);
      expect(stats[CourtZone.top3]!.makes, 2);
      expect(stats[CourtZone.top3]!.makePercentage, closeTo(66.67, 0.1));
      expect(stats[CourtZone.paint]!.attempts, 1);
      expect(session.locatedShots.length, 4);
    });
  });
}
