import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/session.dart';

void main() {
  group('SavedShot JSON', () {
    test('round-trips all fields including form score and feedback', () {
      const shot = SavedShot(
        id: 3,
        startTime: 1.5,
        endTime: 3.0,
        prediction: 'MAKE',
        accuracy: 82.5,
        formScore: 74.0,
        feedback: 'Good shot form',
        ballTrajectory: [Offset(10, 20), Offset(30, 40)],
        hoopPosition: Offset(100, 100),
      );

      final decoded = SavedShot.fromJson(shot.toJson());

      expect(decoded.id, 3);
      expect(decoded.startTime, 1.5);
      expect(decoded.endTime, 3.0);
      expect(decoded.prediction, 'MAKE');
      expect(decoded.accuracy, 82.5);
      expect(decoded.formScore, 74.0);
      expect(decoded.feedback, 'Good shot form');
      expect(decoded.ballTrajectory.length, 2);
      expect(decoded.ballTrajectory.first, const Offset(10, 20));
      expect(decoded.hoopPosition, const Offset(100, 100));
    });

    test('tolerates legacy JSON without the new form fields', () {
      final legacy = {
        'id': 1,
        'start_time': 0.0,
        'end_time': 2.0,
        'prediction': 'MISS',
        'accuracy': 30.0,
        'ball_trajectory': <dynamic>[],
      };
      final decoded = SavedShot.fromJson(legacy);
      expect(decoded.prediction, 'MISS');
      expect(decoded.formScore, isNull);
      expect(decoded.feedback, isNull);
    });
  });

  group('Session aggregates', () {
    Session sessionWith(List<String?> verdicts) => Session(
          id: 's',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          videoPath: '/tmp/x.mp4',
          name: 'Test',
          shots: [
            for (var i = 0; i < verdicts.length; i++)
              SavedShot(
                id: i,
                startTime: 0,
                endTime: 1,
                prediction: verdicts[i],
                ballTrajectory: const [],
              ),
          ],
        );

    test('counts makes, misses and make percentage', () {
      final s = sessionWith(['MAKE', 'MAKE', 'MISS', 'MISS']);
      expect(s.totalShots, 4);
      expect(s.makes, 2);
      expect(s.misses, 2);
      expect(s.makePercentage, 50);
    });

    test('empty session reports zero percent without dividing by zero', () {
      final s = sessionWith(const []);
      expect(s.totalShots, 0);
      expect(s.makePercentage, 0);
    });

    test('round-trips through JSON', () {
      final s = sessionWith(['MAKE', 'MISS']);
      final decoded = Session.fromJson(s.toJson());
      expect(decoded.name, 'Test');
      expect(decoded.totalShots, 2);
      expect(decoded.makes, 1);
    });
  });
}
