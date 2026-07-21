import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/utils/shot_detector.dart';

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

FrameData _frame(
  int i,
  double fps, {
  Offset? ball,
  Offset? rim,
  double rimW = 60,
  double rimH = 45,
  bool motion = false,
}) {
  final dets = <Detection>[];
  if (ball != null) dets.add(_det('ball', ball, 24, 24));
  if (rim != null) dets.add(_det('rim', rim, rimW, rimH));
  return FrameData(
    frameNumber: i,
    timestamp: i / fps,
    detections: dets,
    isShootingMotion: motion,
  );
}

List<FrameData> _seq(
  List<Offset?> balls, {
  Offset? rim,
  double fps = 30,
  Set<int> motionFrames = const {},
  double rimW = 60,
}) {
  return [
    for (int i = 0; i < balls.length; i++)
      _frame(
        i,
        fps,
        ball: balls[i],
        rim: rim,
        rimW: rimW,
        motion: motionFrames.contains(i),
      ),
  ];
}

/// far → near-the-rim → far, around rim (100,100) with rim width 60.
List<Offset> _arcToRim() => const [
      Offset(240, 260), // d ~3.5 (far)
      Offset(160, 110), // d ~1.0 (enters rim vicinity)
      Offset(115, 95), // apex
      Offset(105, 120),
      Offset(100, 160),
      Offset(95, 210), // d ~1.8 (still near)
      Offset(92, 260), // d ~2.7 (leaving)
      Offset(300, 360), // far
      Offset(300, 360),
      Offset(300, 360),
    ];

void main() {
  const rim = Offset(100, 100);

  group('ShotDetector — core (corner angle)', () {
    test('a clear arc into the rim is one shot', () {
      final balls = <Offset?>[
        for (int i = 0; i < 10; i++) const Offset(300, 350), // dribble far
        ..._arcToRim(),
      ];
      final shots = ShotDetector.detect(_seq(balls, rim: rim));
      expect(shots.length, 1);
      expect(shots.first.hoop, isNotNull);
    });

    test('works with NO pose/shoot data (ball trajectory alone)', () {
      final balls = <Offset?>[
        for (int i = 0; i < 10; i++) const Offset(300, 350),
        ..._arcToRim(),
      ];
      // motionFrames empty → no pose/shoot signal at all.
      final shots = ShotDetector.detect(_seq(balls, rim: rim));
      expect(shots.length, 1);
    });

    test('dribbling far from the rim yields no shots', () {
      final balls = <Offset?>[
        for (int i = 0; i < 30; i++) Offset(300 + (i % 3) * 10, 350 + (i % 2) * 8),
      ];
      final shots = ShotDetector.detect(_seq(balls, rim: rim));
      expect(shots, isEmpty);
    });

    test('a ball loitering AT the rim (never approached) is not a shot', () {
      // Always within the rim vicinity but never travelled in from far.
      final balls = <Offset?>[for (int i = 0; i < 30; i++) const Offset(110, 110)];
      final shots = ShotDetector.detect(_seq(balls, rim: rim));
      expect(shots, isEmpty);
    });

    test('two well-separated arcs are two shots', () {
      final balls = <Offset?>[
        for (int i = 0; i < 15; i++) const Offset(300, 350),
        ..._arcToRim(), // ~frames 15-24
        for (int i = 0; i < 70; i++) const Offset(300, 350), // long gap
        ..._arcToRim(), // ~frames 95-104
        for (int i = 0; i < 15; i++) const Offset(300, 350),
      ];
      final shots = ShotDetector.detect(_seq(balls, rim: rim));
      expect(shots.length, 2);
    });
  });

  group('ShotDetector — diagonal pass through the rim', () {
    // From the half-court/sideline corner the ball crosses the rim plane at an
    // angle rather than dropping straight down — the single tuned config still
    // segments it as one shot.
    test('a near-horizontal pass through the rim is one shot', () {
      const courtRim = Offset(300, 120);
      final balls = <Offset?>[
        for (int i = 0; i < 8; i++) const Offset(700, 120), // far to the side
        const Offset(500, 120), // d ~3.3 (far)
        const Offset(380, 120), // enters vicinity
        const Offset(300, 120), // apex (through rim)
        const Offset(220, 130),
        const Offset(120, 160), // leaving
        for (int i = 0; i < 8; i++) const Offset(60, 200),
      ];
      final shots = ShotDetector.detect(_seq(balls, rim: courtRim));
      expect(shots.length, 1);
    });
  });

  group('ShotDetector — fail-proof fallbacks', () {
    test('no rim but shooting motion present still surfaces a window', () {
      final balls = <Offset?>[for (int i = 0; i < 30; i++) Offset(200 + i.toDouble(), 300)];
      final shots = ShotDetector.detect(
        _seq(balls, rim: null, motionFrames: {for (int i = 8; i < 22; i++) i}),
      );
      expect(shots, isNotEmpty);
      expect(shots.first.hoop, isNull); // unscored, but not dropped
    });

    test('no rim and no motion yields no shots', () {
      final balls = <Offset?>[for (int i = 0; i < 30; i++) Offset(200 + i.toDouble(), 300)];
      final shots = ShotDetector.detect(_seq(balls, rim: null));
      expect(shots, isEmpty);
    });

    test('empty input does not crash', () {
      expect(ShotDetector.detect(const []), isEmpty);
    });
  });

  group('ShotDetector — robustness to gaps', () {
    test('a dropped-ball gap mid-arc still detects one shot', () {
      final arc = _arcToRim();
      final balls = <Offset?>[
        for (int i = 0; i < 10; i++) const Offset(300, 350),
        arc[0],
        arc[1],
        null, // YOLO lost the ball at the peak
        arc[3],
        arc[4],
        arc[5],
        arc[6],
        for (int i = 0; i < 8; i++) const Offset(300, 360),
      ];
      final shots = ShotDetector.detect(_seq(balls, rim: rim));
      expect(shots.length, 1);
    });
  });
}
