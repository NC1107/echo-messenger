import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/face_circle_avatar.dart';

void main() {
  group('FaceCircleAvatar', () {
    testWidgets('renders the uppercased first initial', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FaceCircleAvatar(name: 'alice', size: 24)),
        ),
      );
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('falls back to ? for an empty name', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FaceCircleAvatar(name: '', size: 24)),
        ),
      );
      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('same name yields the same (deterministic) colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                FaceCircleAvatar(name: 'bob', size: 24),
                FaceCircleAvatar(name: 'bob', size: 24),
              ],
            ),
          ),
        ),
      );
      final containers = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(FaceCircleAvatar),
              matching: find.byType(Container),
            ),
          )
          .toList();
      expect(containers.length, 2);
      final d0 = containers[0].decoration! as BoxDecoration;
      final d1 = containers[1].decoration! as BoxDecoration;
      expect(d0.color, d1.color);
    });
  });
}
