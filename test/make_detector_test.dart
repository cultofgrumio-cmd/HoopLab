import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/utils/make_detector.dart';

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

/// Build frames from a list of ball positions (null = ball not detected that
/// frame). Optionally add a "made" label on a given frame index.
List<FrameData> _frames(List<Offset?> balls, {int? madeAt, Offset? madePos}) {
  return [
    for (int i = 0; i < balls.length; i++)
      FrameData(
        frameNumber: i,
        timestamp: i / 30,
        detections: [
          if (balls[i] != null) _det('ball', balls[i]!, 20, 20),
          if (madeAt == i) _det('made', madePos ?? const Offset(100, 100), 20, 20),
        ],
      ),
  ];
}

void main() {
  const rimCenter = Offset(100, 100);
  // width 60 → radius 30; rim plane y1=70, y2=130.
  final rimBBox = BoundingBox(x1: 70, y1: 70, x2: 130, y2: 130);

  MakeResult run(List<Offset?> balls, {int? madeAt}) {
    final pts = [for (final b in balls) if (b != null) b];
    return MakeDetector.detect(
      frames: _frames(balls, madeAt: madeAt),
      ballPoints: pts,
      rimCenter: rimCenter,
      rimBBox: rimBBox,
      rimRadius: 30,
    );
  }

  group('MakeDetector', () {
    test('ball dropping through the centre is a make', () {
      final r = run(const [
        Offset(100, 40),
        Offset(100, 70),
        Offset(100, 100),
        Offset(100, 130),
        Offset(100, 180),
      ]);
      expect(r.made, isTrue);
      expect(r.accuracy, greaterThan(80));
    });

    test('a sideways horizontal swish through the rim is a make '
        '(the case the Y-crossing method missed)', () {
      // All y=100: no clean Y-axis rim crossing, but the ball centre passes
      // through the opening.
      final r = run(const [
        Offset(40, 100),
        Offset(70, 100),
        Offset(100, 100),
        Offset(130, 100),
        Offset(160, 100),
      ]);
      expect(r.made, isTrue);
      expect(r.method, 'through opening');
    });

    test('the model "made" label forces a make', () {
      // Ball nowhere near the rim, but the model emitted a "made" label.
      final r = run(
        const [Offset(300, 300), Offset(310, 320), Offset(320, 340)],
        madeAt: 1,
      );
      expect(r.made, isTrue);
      expect(r.method, 'made label');
    });

    test('a net-occlusion swish (above → gap → below) is a make', () {
      // Off-centre so rim-crossing X misses, but column above→below fires.
      final r = run(const [
        Offset(150, 60), // above rim, in column, off to the side
        null, // ball lost in the net
        null,
        Offset(150, 160), // below rim, same column
      ]);
      expect(r.made, isTrue);
    });

    test('a clear miss well wide of the rim is a miss', () {
      final r = run(const [
        Offset(240, 60),
        Offset(240, 100),
        Offset(240, 150),
      ]);
      expect(r.made, isFalse);
    });

    test('a ball that rims out (near but not through) is a miss', () {
      // Closest approach stays outside ~0.9×radius and never passes below.
      final r = run(const [
        Offset(150, 70),
        Offset(148, 95),
        Offset(152, 118),
        Offset(200, 90),
      ]);
      expect(r.made, isFalse);
    });

    // ---- Off-centre / edge makes (the "clean make scored as miss" bug) -------

    group('off-centre makes through the real rim opening', () {
      // A wider, thinner rim (perspective): width 80 (radius 40), height 30.
      // Centre (240,165); opening box x∈[200,280], y∈[150,180].
      final wideRim = BoundingBox(x1: 200, y1: 150, x2: 280, y2: 180);
      const wideCenter = Offset(240, 165);

      MakeResult runWide(List<Offset?> balls, {int? madeAt, Offset? madePos}) {
        final pts = [for (final b in balls) if (b != null) b];
        return MakeDetector.detect(
          frames: _frames(balls, madeAt: madeAt, madePos: madePos),
          ballPoints: pts,
          rimCenter: wideCenter,
          rimBBox: wideRim,
          rimRadius: 40,
        );
      }

      test('a ball crossing the rim near the edge is a make, not a miss', () {
        // Crosses the rim centre line (y=165) at x≈279 — inside the span but far
        // from the geometric centre, so the old circle test called it a miss.
        final r = runWide(const [
          Offset(290, 80),
          Offset(285, 120),
          Offset(281, 150),
          Offset(278, 180),
          Offset(274, 240),
        ]);
        expect(r.made, isTrue);
        expect(r.method, 'rim crossing');
      });

      test('a clean off-centre swish lost in the net is a make', () {
        // Ball descends through the right side of the ring, then disappears in
        // the net (never re-detected below) — the common real-world make.
        final r = runWide(const [
          Offset(285, 90),
          Offset(282, 130),
          Offset(279, 160),
          Offset(277, 178), // last seen inside the ring
          null, null, null, // lost in the net
        ]);
        expect(r.made, isTrue);
      });

      test('a make survives the ball being lost in some frames', () {
        // ballPoints.length != frames.length (ball missing on some frames).
        final r = runWide(const [
          Offset(250, 60),
          null,
          Offset(247, 100),
          null,
          Offset(244, 140),
          null,
          Offset(240, 200),
          Offset(236, 280),
        ]);
        expect(r.made, isTrue);
      });

      test('a shot long over the rim (crosses wide of the span) is a miss', () {
        // Descends behind the rim: crosses y=165 at x≈150, well left of the
        // opening — a genuine miss that must not be rescued as a make.
        final r = runWide(const [
          Offset(170, 80),
          Offset(160, 120),
          Offset(150, 160),
          Offset(140, 220),
          Offset(130, 300),
        ]);
        expect(r.made, isFalse);
      });
    });
  });
}
