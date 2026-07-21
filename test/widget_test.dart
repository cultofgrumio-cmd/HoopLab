// Smoke test: the app boots to the method-selection landing screen.

import 'package:flutter_test/flutter_test.dart';

import 'package:hooplab/main.dart';

void main() {
  testWidgets('App launches to the Choose Method screen', (tester) async {
    await tester.pumpWidget(const App());
    // Let the entrance animation settle.
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Choose Method'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
  });
}
