import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/safety_number_screen.dart';
import 'package:echo_app/src/services/safety_number_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';
import '../helpers/pump_app.dart';

void main() {
  group('SafetyNumberScreen (#580)', () {
    late FakeSecureKeyStore fakeStore;

    setUp(() {
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets(
      'renders the formatted safety number when both keys are present',
      (tester) async {
        // Pre-populate identity keys for the screen to read directly.
        final myKey = List<int>.generate(32, (i) => i);
        final peerKey = List<int>.generate(32, (i) => 200 - i);
        await fakeStore.write('echo_identity_pub_key', base64Encode(myKey));
        await fakeStore.write(
          'echo_peer_identity_peer-1',
          base64Encode(peerKey),
        );

        // Pre-compute the expected safety number so we know the formatted
        // string will appear on screen. Determinism is verified by the
        // SafetyNumberService tests; here we only assert the screen
        // renders the format.
        await SafetyNumberService.generate(
          // ignore: prefer_typing_uninitialized_variables
          base64Decode(base64Encode(myKey)),
          base64Decode(base64Encode(peerKey)),
        );

        await tester.pumpScreen(
          const SafetyNumberScreen(
            peerUserId: 'peer-1',
            peerUsername: 'alice',
            myUsername: 'me',
          ),
        );

        // First frame shows the loading spinner; pumping settles the
        // async fingerprint generation.
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();

        // The screen formats digits in groups of 5 -- look for any string of
        // 5 digits separated by spaces. We don't pin the exact number to
        // avoid coupling to the hash output.
        final digitGroups = find.byWidgetPredicate((w) {
          if (w is! Text) return false;
          final t = w.data;
          return t != null && RegExp(r'\d{5}( \d{5})+').hasMatch(t);
        });
        expect(digitGroups, findsAtLeastNWidgets(1));

        // The "Mark as Verified" CTA should be present.
        expect(find.text('Mark as Verified'), findsOneWidget);
      },
    );

    testWidgets('shows error state when the local identity key is missing', (
      tester,
    ) async {
      // No keys in the store -> screen falls into its error branch.
      await tester.pumpScreen(
        const SafetyNumberScreen(
          peerUserId: 'peer-1',
          peerUsername: 'alice',
          myUsername: 'me',
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('encryption keys have not been set up'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
