import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/voice/participant_attention.dart';

void main() {
  group('attentionFor', () {
    test('isSpeaking → speaking, regardless of room state', () {
      expect(
        attentionFor(isSpeaking: true, anyoneElseSpeaking: false),
        ParticipantAttention.speaking,
      );
      expect(
        attentionFor(isSpeaking: true, anyoneElseSpeaking: true),
        ParticipantAttention.speaking,
      );
    });

    test('not speaking but room has another speaker → faded', () {
      expect(
        attentionFor(isSpeaking: false, anyoneElseSpeaking: true),
        ParticipantAttention.faded,
      );
    });

    test('quiet room → idle', () {
      expect(
        attentionFor(isSpeaking: false, anyoneElseSpeaking: false),
        ParticipantAttention.idle,
      );
    });
  });
}
