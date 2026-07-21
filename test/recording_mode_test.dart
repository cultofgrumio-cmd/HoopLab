import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/utils/live_shot_tracker.dart';
import 'package:hooplab/utils/shot_detector.dart';
import 'package:hooplab/utils/shot_predictor.dart';
import 'package:hooplab/utils/shot_quality_evaluator.dart';
import 'package:hooplab/utils/trajectory_prediction.dart' show ShotConfidence;

// ---- frame builders (mirrors shot_detector_test) --------------------------

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

List<FrameData> _seq(List<Offset?> balls, {Offset? rim, double fps = 30}) => [
      for (int i = 0; i < balls.length; i++)
        FrameData(
          frameNumber: i,
          timestamp: i / fps,
          detections: [
            if (balls[i] != null) _det('ball', balls[i]!, 24, 24),
            if (rim != null) _det('rim', rim, 60, 45),
          ],
        ),
    ];

/// far → into the rim vicinity → far, around rim (100,100), width 60.
List<Offset> _arcToRim() => const [
      Offset(240, 260),
      Offset(160, 110),
      Offset(115, 95),
      Offset(105, 120),
      Offset(100, 160),
      Offset(95, 210),
      Offset(92, 260),
      Offset(300, 360),
      Offset(300, 360),
      Offset(300, 360),
    ];

void main() {
  group('RecordingMode storage keys', () {
    test('round-trips through fromStorageKey', () {
      for (final mode in RecordingMode.values) {
        expect(
          RecordingModeInfo.fromStorageKey(mode.storageKey),
          mode,
        );
      }
    });

    test('unknown / empty keys default to tripod', () {
      expect(RecordingModeInfo.fromStorageKey('garbage'), RecordingMode.tripod);
      expect(RecordingModeInfo.fromStorageKey(''), RecordingMode.tripod);
    });

    test('every mode exposes non-empty copy', () {
      for (final mode in RecordingMode.values) {
        expect(mode.label, isNotEmpty);
        expect(mode.shortLabel, isNotEmpty);
        expect(mode.description, isNotEmpty);
        expect(mode.setupTip, isNotEmpty);
      }
    });
  });

  group('ShotDetectorConfig.forMode', () {
    test('ground is looser than tripod on approach + trail + gaps', () {
      final tripod = ShotDetectorConfig.forMode(RecordingMode.tripod);
      final ground = ShotDetectorConfig.forMode(RecordingMode.ground);
      expect(ground.approachFactor, greaterThan(tripod.approachFactor));
      expect(ground.trailSeconds, greaterThan(tripod.trailSeconds));
      expect(ground.gapToleranceFrames,
          greaterThanOrEqualTo(tripod.gapToleranceFrames));
    });

    test('both presets still segment a clean arc into the rim', () {
      final balls = <Offset?>[
        for (int i = 0; i < 10; i++) const Offset(300, 350),
        ..._arcToRim(),
      ];
      for (final mode in RecordingMode.values) {
        final shots = ShotDetector.detect(
          _seq(balls, rim: const Offset(100, 100)),
          config: ShotDetectorConfig.forMode(mode),
        );
        expect(shots.length, 1, reason: 'mode=$mode');
        expect(shots.first.hoop, isNotNull);
      }
    });
  });

  group('LiveShotTracker.forMode', () {
    // A clean make through the right edge of the rim opening. The far point is
    // well beyond both modes' farFactor so the attempt arms in either mode.
    const edgeMake = <Offset>[
      Offset(340, 40), // far → arms
      Offset(160, 95), // enters the rim zone
      Offset(128, 100), // through the opening, right edge
      Offset(126, 118),
      Offset(130, 180),
      Offset(240, 320), // leaves → finalise
    ];

    Detection rimDet() => _det('rim', const Offset(100, 100), 60, 45);

    LiveShotEvent? runPath(LiveShotTracker t, List<Offset> path) {
      LiveShotEvent? ev;
      for (int i = 0; i < path.length; i++) {
        final e =
            t.onDetections([rimDet(), _det('ball', path[i], 24, 24)], i * 0.1);
        if (e != null) ev = e;
      }
      return ev;
    }

    test('only segmentation is tuned per mode (not the make decision)', () {
      final tripod = LiveShotTracker.forMode(RecordingMode.tripod);
      final ground = LiveShotTracker.forMode(RecordingMode.ground);
      expect(ground.approachFactor, greaterThan(tripod.approachFactor));
      expect(ground.farFactor, greaterThan(tripod.farFactor));
    });

    test('both modes use the same improved (opening-box) make detection', () {
      // An edge make the old distance-to-centre heuristic scored as a miss —
      // both modes now delegate to the shared MakeDetector and call it a make.
      for (final mode in RecordingMode.values) {
        final t = LiveShotTracker.forMode(mode);
        final ev = runPath(t, edgeMake);
        expect(ev, isNotNull, reason: 'mode=$mode');
        expect(ev!.made, isTrue, reason: 'mode=$mode');
        expect(t.makes, 1, reason: 'mode=$mode');
      }
    });
  });

  group('ShotArcProfile.forMode / ShotQualityEvaluator', () {
    test('ground shifts the good bands lower', () {
      final tripod = ShotArcProfile.forMode(RecordingMode.tripod);
      final ground = ShotArcProfile.forMode(RecordingMode.ground);
      expect(ground.releaseIdealLow, lessThan(tripod.releaseIdealLow));
      expect(ground.arcRatioIdealLow, lessThan(tripod.arcRatioIdealLow));
    });

    test('a flat, shallow arc scores higher under the ground profile', () {
      // Shallow release (~30°) and a low arc — penalised on a tripod, but
      // expected geometry for a tilted-up ground shot.
      const flat = <Offset>[
        Offset(100, 200),
        Offset(130, 182),
        Offset(160, 166),
        Offset(210, 150),
        Offset(260, 158),
        Offset(300, 175),
        Offset(330, 200),
      ];
      const hoop = Offset(300, 100);

      final tripod = ShotQualityEvaluator.evaluateShotQuality(
        ballTrajectory: flat,
        hoopPosition: hoop,
        profile: ShotArcProfile.forMode(RecordingMode.tripod),
      );
      final ground = ShotQualityEvaluator.evaluateShotQuality(
        ballTrajectory: flat,
        hoopPosition: hoop,
        profile: ShotArcProfile.forMode(RecordingMode.ground),
      );
      expect(ground.overallScore, greaterThan(tripod.overallScore));
    });
  });

  group('ShotPredictorConfig.forMode', () {
    ({List<Offset> pts, List<double> ts}) launch() {
      const vx = 122.5, y0 = 400.0, vy = -500.0, g = 500.0, apexT = 1.0;
      final pts = <Offset>[];
      final ts = <double>[];
      for (int i = 0; i < 6; i++) {
        final t = apexT * i / 5;
        pts.add(Offset(vx * t, y0 + vy * t + 0.5 * g * t * t));
        ts.add(t);
      }
      return (pts: pts, ts: ts);
    }

    test('ground caps release-prediction confidence below high', () {
      final l = launch();
      final tripod = ShotPredictor.predictFromRelease(
        ballPoints: l.pts,
        timestamps: l.ts,
        rimCenter: const Offset(200, 250),
        rimRadius: 30,
        config: ShotPredictorConfig.forMode(RecordingMode.tripod),
      );
      final ground = ShotPredictor.predictFromRelease(
        ballPoints: l.pts,
        timestamps: l.ts,
        rimCenter: const Offset(200, 250),
        rimRadius: 30,
        config: ShotPredictorConfig.forMode(RecordingMode.ground),
      );
      expect(tripod.confidence, ShotConfidence.high);
      // Same clean arc, but the ground rig can't claim high confidence.
      expect(ground.confidence, ShotConfidence.medium);
      // The verdict itself is unchanged.
      expect(ground.willMake, tripod.willMake);
    });
  });
}
