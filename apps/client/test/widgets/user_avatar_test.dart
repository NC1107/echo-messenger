import 'package:echo_app/src/widgets/user_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/pump_app.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('UserAvatar', () {
    testWidgets('renders fallback initial when no avatar URL', (tester) async {
      await tester.pumpApp(
        const UserAvatar(userId: 'u1', username: 'jane', radius: 18),
      );
      expect(find.text('J'), findsOneWidget);
    });

    testWidgets('wires a GestureDetector when openProfileOnTap is on', (
      tester,
    ) async {
      await tester.pumpApp(
        const UserAvatar(userId: 'u1', username: 'jane', radius: 18),
      );
      expect(find.byType(GestureDetector), findsOneWidget);
    });

    testWidgets('skips the GestureDetector when openProfileOnTap is off', (
      tester,
    ) async {
      await tester.pumpApp(
        const UserAvatar(
          userId: 'u1',
          username: 'jane',
          radius: 18,
          openProfileOnTap: false,
        ),
      );
      expect(find.byType(GestureDetector), findsNothing);
    });

    testWidgets('custom onTap fires when the avatar is tapped', (tester) async {
      var taps = 0;
      await tester.pumpApp(
        UserAvatar(
          userId: 'u1',
          username: 'jane',
          radius: 18,
          onTap: () => taps++,
        ),
      );
      await tester.tap(find.byType(GestureDetector));
      await tester.pump();
      expect(taps, 1);
    });
  });
}
