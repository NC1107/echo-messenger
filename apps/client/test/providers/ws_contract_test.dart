import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/ws_message_types.dart';

void main() {
  group('WS server↔client event contract', () {
    test('every server-sent ServerMessage type is handled by the client', () {
      // The server's typed `ServerMessage` events (protocol.rs) must each have
      // a client handler, or they are silently dropped on the wire. If this
      // fails, add a `case` in WsMessageHandler.handleServerMessage and the
      // string to kHandledServerMessageTypes.
      final unhandled = kServerSentMessageTypes.difference(
        kHandledServerMessageTypes,
      );
      expect(
        unhandled,
        isEmpty,
        reason:
            'These server ServerMessage events have NO client handler and '
            'would be silently dropped: $unhandled',
      );
    });

    test(
      'contract sets are populated (guards an accidentally-emptied list)',
      () {
        expect(kServerSentMessageTypes, isNotEmpty);
        expect(kHandledServerMessageTypes, isNotEmpty);
        // The handled set covers the typed contract plus ad-hoc broadcasts.
        expect(
          kHandledServerMessageTypes.length,
          greaterThanOrEqualTo(kServerSentMessageTypes.length),
        );
      },
    );
  });
}
