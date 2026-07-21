import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/session.dart';
import 'package:hooplab/utils/court.dart';
import 'package:hooplab/widgets/court_painter.dart';

SavedShot _shot(int id, Offset court, String zone, bool make) => SavedShot(
      id: id,
      startTime: 0,
      endTime: 1,
      prediction: make ? 'MAKE' : 'MISS',
      ballTrajectory: const [],
      courtPosition: court,
      zone: zone,
    );

void main() {
  // Shots spanning several zones so every zone-path branch is exercised.
  final shots = [
    _shot(0, const Offset(0, 2), 'restricted', true),
    _shot(1, const Offset(3, 9), 'paint', true),
    _shot(2, const Offset(-13, 12), 'midLeft', false),
    _shot(3, const Offset(0, 19), 'midCenter', true),
    _shot(4, const Offset(13, 12), 'midRight', false),
    _shot(5, const Offset(-23, 3), 'cornerLeft3', false),
    _shot(6, const Offset(23, 3), 'cornerRight3', true),
    _shot(7, const Offset(-20, 18), 'wingLeft3', false),
    _shot(8, const Offset(0, 26), 'top3', true),
    _shot(9, const Offset(20, 18), 'wingRight3', true),
  ];

  Map<CourtZone, ZoneStat> statsFor(List<SavedShot> s) {
    final out = <CourtZone, ZoneStat>{};
    for (final shot in s) {
      final z = shot.courtZone!;
      final stat = out.putIfAbsent(z, () => ZoneStat(z));
      stat.attempts++;
      if (shot.isMake) stat.makes++;
    }
    return out;
  }

  void render(CourtView view, List<SavedShot> s) {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    CourtPainter(
      shots: s,
      zoneStats: statsFor(s),
      view: view,
      lineColor: const Color(0xFF000000),
      courtFill: const Color(0xFFF3E5CB),
      labelColor: const Color(0xFFFFFFFF),
    ).paint(canvas, const Size(360, 340));
    recorder.endRecording();
  }

  test('paints every view without throwing', () {
    for (final view in CourtView.values) {
      expect(() => render(view, shots), returnsNormally);
    }
  });

  test('paints cleanly with no shots', () {
    for (final view in CourtView.values) {
      expect(() => render(view, const []), returnsNormally);
    }
  });
}
