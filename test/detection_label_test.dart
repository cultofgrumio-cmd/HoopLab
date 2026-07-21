import 'package:flutter_test/flutter_test.dart';
import 'package:hooplab/models/clip.dart';

Detection _det(String label) => Detection(
      trackId: 0,
      bbox: BoundingBox(x1: 0, y1: 0, x2: 10, y2: 10),
      confidence: 0.9,
      timestamp: 0,
      label: label,
    );

void main() {
  group('DetectionLabel', () {
    test('matches canonical string names', () {
      expect(_det('ball').isBall, isTrue);
      expect(_det('made').isMade, isTrue);
      expect(_det('person').isPerson, isTrue);
      expect(_det('rim').isRim, isTrue);
      expect(_det('shoot').isShoot, isTrue);
    });

    test('matches numeric class ids from the model', () {
      // Model classes: 0=ball, 1=made, 2=person, 3=rim, 4=shoot
      expect(_det('0').isBall, isTrue);
      expect(_det('1').isMade, isTrue);
      expect(_det('2').isPerson, isTrue);
      expect(_det('3').isRim, isTrue);
      expect(_det('4').isShoot, isTrue);
    });

    test('accepts legacy hoop/basket aliases as rim', () {
      expect(_det('hoop').isRim, isTrue);
      expect(_det('basket').isRim, isTrue);
    });

    test('is case-insensitive and trims whitespace', () {
      expect(_det(' Ball ').isBall, isTrue);
      expect(_det('RIM').isRim, isTrue);
    });

    test('does not cross-match unrelated classes', () {
      expect(_det('ball').isRim, isFalse);
      expect(_det('rim').isBall, isFalse);
      expect(_det('person').isShoot, isFalse);
    });
  });
}
