import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/theme_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/widgets/chat_panel.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

/// Notifier we can mutate from the test body.
class _FakeChatNotifier extends ChatNotifier {
  _FakeChatNotifier(super.ref, ChatState initial) {
    state = initial;
  }

  @override
  Future<void> loadHistoryWithUserId(
    String conversationId,
    String token,
    String userId, {
    String? channelId,
    String? before,
    CryptoService? crypto,
    GroupCryptoService? groupCrypto,
    bool isGroup = false,
  }) async {}

  void setMessages(String conversationId, List<ChatMessage> messages) {
    state = state.copyWith(
      messagesByConversation: {
        ...state.messagesByConversation,
        conversationId: messages,
      },
    );
  }
}

class _FakeChannelsNotifier extends ChannelsNotifier {
  _FakeChannelsNotifier(super.ref) {
    state = const ChannelsState();
  }

  @override
  Future<void> loadChannels(String conversationId) async {}
}

class _FakePrivacyNotifier extends PrivacyNotifier {
  _FakePrivacyNotifier(super.ref) {
    state = const PrivacyState();
  }
}

class _FakeVoiceSettingsNotifier extends VoiceSettingsNotifier {
  _FakeVoiceSettingsNotifier() {
    state = const VoiceSettingsState();
  }
}

class _FakeVoiceRtcNotifier extends LiveKitVoiceNotifier {
  _FakeVoiceRtcNotifier(super.ref);
}

class _FakeTheme extends AppTheme {
  @override
  AppThemeSelection build() => AppThemeSelection.dark;
}

class _FakeMessageLayoutNotifier extends MessageLayoutNotifier {
  @override
  MessageLayout build() => MessageLayout.bubbles;
}

const _conv = Conversation(
  id: 'conv-dm',
  isGroup: false,
  isEncrypted: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
  ],
);

ChatMessage _peerMsg(String id, {String content = 'Hello there'}) {
  return ChatMessage(
    id: id,
    fromUserId: 'user-alice',
    fromUsername: 'alice',
    conversationId: 'conv-dm',
    content: content,
    timestamp: '2026-01-15T10:00:00Z',
    isMine: false,
  );
}

ChatMessage _ownMsg(String id, {String content = 'My reply'}) {
  return ChatMessage(
    id: id,
    fromUserId: 'test-user-id',
    fromUsername: 'testuser',
    conversationId: 'conv-dm',
    content: content,
    timestamp: '2026-01-15T10:01:00Z',
    isMine: true,
  );
}

/// Holds a reference to the fake ChatNotifier created via Riverpod's
/// `overrideWith` callback so the test body can mutate state.
class _NotifierHolder {
  _FakeChatNotifier? notifier;
}

List<Override> _overrides({
  required ChatState initial,
  required _NotifierHolder holder,
}) {
  return [
    ...standardOverrides(),
    chatProvider.overrideWith((ref) {
      final n = _FakeChatNotifier(ref, initial);
      holder.notifier = n;
      return n;
    }),
    channelsProvider.overrideWith((ref) => _FakeChannelsNotifier(ref)),
    privacyProvider.overrideWith((ref) => _FakePrivacyNotifier(ref)),
    voiceSettingsProvider.overrideWith((ref) => _FakeVoiceSettingsNotifier()),
    voiceRtcProvider.overrideWith((ref) => _FakeVoiceRtcNotifier(ref)),
    appThemeProvider.overrideWith(_FakeTheme.new),
    messageLayoutNotifierProvider.overrideWith(_FakeMessageLayoutNotifier.new),
  ];
}

/// Find every Semantics widget in the tree configured as a live region.
List<String> _liveRegionLabels(WidgetTester tester) {
  return tester
      .widgetList<Semantics>(find.byType(Semantics))
      .where((s) => s.properties.liveRegion == true)
      .map((s) => s.properties.label ?? '')
      .toList();
}

void main() {
  group('ChatPanel live region (#495)', () {
    testWidgets('hidden Semantics live region exists in the tree', (
      tester,
    ) async {
      final holder = _NotifierHolder();
      await tester.pumpApp(
        ChatPanel(conversation: _conv),
        overrides: _overrides(initial: const ChatState(), holder: holder),
      );
      await tester.pump();

      final labels = _liveRegionLabels(tester);
      expect(labels, isNotEmpty);
      // Initial label is empty until the first peer announcement.
      expect(labels.every((l) => l.isEmpty), isTrue);
    });

    testWidgets('peer message updates live region label', (tester) async {
      final holder = _NotifierHolder();
      // Seed with one peer message so prevCount > 0 when the next arrives
      // (the initial-load guard requires prevCount > 0).
      final initial = ChatState(
        messagesByConversation: {
          'conv-dm': [_peerMsg('m1', content: 'first')],
        },
      );

      await tester.pumpApp(
        ChatPanel(conversation: _conv),
        overrides: _overrides(initial: initial, holder: holder),
      );
      await tester.pump();

      holder.notifier!.setMessages('conv-dm', [
        _peerMsg('m1', content: 'first'),
        _peerMsg('m2', content: 'hello world'),
      ]);
      await tester.pump();

      final updated = _liveRegionLabels(tester);
      expect(
        updated.any(
          (l) =>
              l.contains('New message from alice') && l.contains('hello world'),
        ),
        isTrue,
        reason: 'expected an announcement label, got $updated',
      );
    });

    testWidgets('own message does NOT update live region', (tester) async {
      final holder = _NotifierHolder();
      final initial = ChatState(
        messagesByConversation: {
          'conv-dm': [_peerMsg('m1', content: 'first')],
        },
      );

      await tester.pumpApp(
        ChatPanel(conversation: _conv),
        overrides: _overrides(initial: initial, holder: holder),
      );
      await tester.pump();

      holder.notifier!.setMessages('conv-dm', [
        _peerMsg('m1', content: 'first'),
        _ownMsg('m2', content: 'my reply'),
      ]);
      await tester.pump();

      // Still empty — own message never triggers an announcement.
      final labels = _liveRegionLabels(tester);
      expect(labels.every((l) => l.isEmpty), isTrue);
    });

    testWidgets('duplicate tail id does NOT re-announce', (tester) async {
      final holder = _NotifierHolder();
      final initial = ChatState(
        messagesByConversation: {
          'conv-dm': [_peerMsg('m1', content: 'first')],
        },
      );

      await tester.pumpApp(
        ChatPanel(conversation: _conv),
        overrides: _overrides(initial: initial, holder: holder),
      );
      await tester.pump();

      // First peer arrival → announcement for m2.
      holder.notifier!.setMessages('conv-dm', [
        _peerMsg('m1', content: 'first'),
        _peerMsg('m2', content: 'second'),
      ]);
      await tester.pump();
      final firstLabel = _liveRegionLabels(
        tester,
      ).firstWhere((l) => l.isNotEmpty, orElse: () => '');
      expect(firstLabel, contains('second'));

      // Append an own message: tail is now own, so no new announcement
      // should fire and the live region label should remain unchanged
      // (own messages never update the announcement).
      holder.notifier!.setMessages('conv-dm', [
        _peerMsg('m1', content: 'first'),
        _peerMsg('m2', content: 'second'),
        _ownMsg('m3', content: 'mine'),
      ]);
      await tester.pump();

      final after = _liveRegionLabels(
        tester,
      ).firstWhere((l) => l.isNotEmpty, orElse: () => '');
      expect(after, equals(firstLabel));
    });

    testWidgets(
      'peer message arrival is discoverable via find.bySemanticsLabel (#630)',
      (tester) async {
        final holder = _NotifierHolder();
        final initial = ChatState(
          messagesByConversation: {
            'conv-dm': [_peerMsg('m1', content: 'first')],
          },
        );

        await tester.pumpApp(
          ChatPanel(conversation: _conv),
          overrides: _overrides(initial: initial, holder: holder),
        );
        await tester.pump();

        holder.notifier!.setMessages('conv-dm', [
          _peerMsg('m1', content: 'first'),
          _peerMsg('m2', content: 'hello stable region'),
        ]);
        await tester.pump();

        // The Semantics liveRegion is mounted at a stable index in the
        // outer Stack, so screen readers (and find.bySemanticsLabel) can
        // discover the announcement label directly.
        expect(
          find.bySemanticsLabel('New message from alice: hello stable region'),
          findsOneWidget,
        );
      },
    );

    testWidgets('initial history load (prevCount==0) does NOT announce', (
      tester,
    ) async {
      final holder = _NotifierHolder();

      await tester.pumpApp(
        ChatPanel(conversation: _conv),
        overrides: _overrides(initial: const ChatState(), holder: holder),
      );
      await tester.pump();

      // History finishes async, prevCount transitions 0 → N. No announce.
      holder.notifier!.setMessages('conv-dm', [
        _peerMsg('m1', content: 'history line one'),
        _peerMsg('m2', content: 'history line two'),
      ]);
      await tester.pump();

      final labels = _liveRegionLabels(tester);
      expect(labels.every((l) => l.isEmpty), isTrue);
    });
  });
}
