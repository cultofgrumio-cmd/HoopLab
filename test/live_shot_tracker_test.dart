import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/services/audio_feedback.dart';
import 'package:hooplab/utils/live_shot_tracker.dart';

Detection _det(String label, Offset c, {double w = 20, double h = 20}) =>
    Detection(
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

const rim = Offset(100, 100);
Detection _rimDet() => _det('rim', rim, w: 60, h: 45);

void main() {
  // A made shot: ball arcs in from far, passes through the rim centre, exits.
  const makePath = <Offset>[
    Offset(300, 60), // far → arms
    Offset(200, 80), // enters rim zone
    Offset(140, 95),
    Offset(100, 100), // through the centre
    Offset(80, 120),
    Offset(60, 180),
    Offset(40, 300), // leaves the zone → finalize
  ];

  // A miss: comes near the rim but stays wide, never through.
  const missPath = <Offset>[
    Offset(400, 60), // far → arms
    Offset(300, 80),
    Offset(240, 95),
    Offset(200, 110), // near but wide
    Offset(180, 130),
    Offset(170, 160),
    Offset(200, 260), // leaves the zone → finalize
  ];

  group('LiveShotTracker', () {
    test('scores a make when the ball passes through the rim', () {
      final t = LiveShotTracker();
      LiveShotEvent? event;
      for (int i = 0; i < makePath.length; i++) {
        final e =
            t.onDetections([_rimDet(), _det('ball', makePath[i])], i * 0.1);
        if (e != null) event = e;
      }
      expect(event, isNotNull);
      expect(event!.made, isTrue);
      expect(t.makes, 1);
      expect(t.total, 1);
      expect(t.streak, 1);
    });

    test('scores a make through the edge of the rim opening', () {
      // Passes through the opening near the right edge: its closest approach to
      // the rim CENTRE (~28px) exceeds 0.9×radius (27px), so the old
      // distance-to-centre test scored it a miss. Passing through the opening
      // box makes it a make.
      const edgeMake = <Offset>[
        Offset(300, 60), // far → arms
        Offset(160, 95), // enters rim zone
        Offset(128, 100), // through the opening, right edge
        Offset(126, 118),
        Offset(130, 180),
        Offset(200, 300), // leaves the zone → finalize
      ];
      final t = LiveShotTracker();
      LiveShotEvent? event;
      for (int i = 0; i < edgeMake.length; i++) {
        final e =
            t.onDetections([_rimDet(), _det('ball', edgeMake[i])], i * 0.1);
        if (e != null) event = e;
      }
      expect(event, isNotNull);
      expect(event!.made, isTrue);
      expect(t.makes, 1);
    });

    test('scores a miss when the ball stays wide of the rim', () {
      final t = LiveShotTracker();
      LiveShotEvent? event;
      for (int i = 0; i < missPath.length; i++) {
        final e =
            t.onDetections([_rimDet(), _det('ball', missPath[i])], i * 0.1);
        if (e != null) event = e;
      }
      expect(event, isNotNull);
      expect(event!.made, isFalse);
      expect(t.misses, 1);
      expect(t.streak, 0);
    });

    test('builds a streak across consecutive makes and resets on a miss', () {
      final t = LiveShotTracker();
      double time = 0;
      for (var s = 0; s < 2; s++) {
        for (final p in makePath) {
          t.onDetections([_rimDet(), _det('ball', p)], time);
          time += 0.1;
        }
        time += 2; // gap > refractory
      }
      expect(t.makes, 2);
      expect(t.streak, 2);

      for (final p in missPath) {
        t.onDetections([_rimDet(), _det('ball', p)], time);
        time += 0.1;
      }
      expect(t.streak, 0);
      expect(t.total, 3);
    });
  });

  group('liveAnnouncement', () {
    LiveShotEvent ev({required bool made, int total = 1, int streak = 1}) =>
        LiveShotEvent(
          made: made,
          total: total,
          makes: made ? total : total - 1,
          misses: made ? 0 : 1,
          streak: streak,
        );

    test('says nothing when no options are enabled', () {
      expect(liveAnnouncement(ev(made: true), {}), isNull);
    });

    test('calls make/miss when enabled', () {
      expect(
        liveAnnouncement(ev(made: true), {LiveFeedbackType.makeMiss}),
        'Make',
      );
      expect(
        liveAnnouncement(ev(made: false), {LiveFeedbackType.makeMiss}),
        'Miss',
      );
    });

    test('announces a streak only on makes of 2+', () {
      expect(
        liveAnnouncement(
          ev(made: true, streak: 3),
          {LiveFeedbackType.streak},
        ),
        '3 in a row',
      );
      // streak of 1 → not announced
      expect(
        liveAnnouncement(
          ev(made: true, streak: 1),
          {LiveFeedbackType.streak},
        ),
        isNull,
      );
    });

    test('announces total shots with correct pluralisation', () {
      expect(
        liveAnnouncement(ev(made: true, total: 1), {LiveFeedbackType.total}),
        '1 shot',
      );
      expect(
        liveAnnouncement(ev(made: true, total: 5), {LiveFeedbackType.total}),
        '5 shots',
      );
    });

    test('combines enabled options in order', () {
      final phrase = liveAnnouncement(
        ev(made: true, total: 4, streak: 4),
        {LiveFeedbackType.makeMiss, LiveFeedbackType.streak, LiveFeedbackType.total},
      );
      expect(phrase, 'Make. 4 in a row. 4 shots');
    });
  });
}
