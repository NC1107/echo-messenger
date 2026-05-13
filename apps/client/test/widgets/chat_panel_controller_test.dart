/// Unit tests for [ChatPanelController]'s per-channel state caches.
///
/// Focused on the regression where switching between two groups would lose
/// the saved scroll offset because the channel id was reset to `null`
/// before the per-channel cache lookup.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/chat_panel_controller.dart';

void main() {
  group('ChatPanelController per-channel state cache', () {
    test('cacheKeyFor reflects current selectedTextChannelId', () {
      final c = ChatPanelController();
      c.selectedTextChannelId = 'general';
      expect(c.cacheKeyFor('groupA'), 'groupA:general');

      c.selectedTextChannelId = null;
      expect(c.cacheKeyFor('groupA'), 'groupA:');
    });

    test(
      'lastChannelByConversation maps conv id to its last viewed channel',
      () {
        final c = ChatPanelController();
        c.lastChannelByConversation['groupA'] = 'general';
        c.lastChannelByConversation['groupB'] = 'random';

        expect(c.lastChannelByConversation['groupA'], 'general');
        expect(c.lastChannelByConversation['groupB'], 'random');
        expect(c.lastChannelByConversation['neverVisited'], isNull);
      },
    );

    test(
      'group-switch round-trip preserves scroll offset under per-channel key',
      () {
        // Simulates: user in groupA/general scrolls to bottom, switches to
        // groupB, then returns to groupA. The fix routes the channel through
        // lastChannelByConversation so cacheKeyFor returns the SAME key on
        // restore as on save.
        final c = ChatPanelController();

        // 1. User is in groupA on the 'general' channel.
        c.selectedTextChannelId = 'general';
        final keyAtSave = c.cacheKeyFor('groupA');
        c.scrollPositions[keyAtSave] = 1240.0;
        c.lastChannelByConversation['groupA'] = c.selectedTextChannelId;

        // 2. Switch to groupB. The widget would normally reset
        //    selectedTextChannelId; here we just set it to whatever B's
        //    default would be (or null for "no channel picked yet").
        c.selectedTextChannelId = null;

        // 3. Coming back to groupA — restore the saved channel BEFORE the
        //    lookup. This is the fix: lastChannelByConversation lets the
        //    cacheKeyFor lookup match the saved key.
        c.selectedTextChannelId = c.lastChannelByConversation['groupA'];
        final keyAtRestore = c.cacheKeyFor('groupA');

        expect(keyAtRestore, keyAtSave);
        expect(c.scrollPositions[keyAtRestore], 1240.0);
      },
    );

    test(
      'pre-fix behavior: lookup with null channel misses the saved per-channel offset',
      () {
        // Documents what was wrong BEFORE the fix. If we reset the channel
        // to null and never restore it, the cacheKeyFor lookup produces a
        // different key than what was saved.
        final c = ChatPanelController();

        c.selectedTextChannelId = 'general';
        c.scrollPositions[c.cacheKeyFor('groupA')] = 1240.0;

        // Switch resets channel to null — the (buggy) lookup misses.
        c.selectedTextChannelId = null;
        final keyWithoutChannelRestore = c.cacheKeyFor('groupA');

        expect(keyWithoutChannelRestore, 'groupA:');
        expect(
          c.scrollPositions[keyWithoutChannelRestore],
          isNull,
          reason: 'Saved under groupA:general; null-channel lookup must miss',
        );
      },
    );

    test('DM round-trip (no channel) hits the cache', () {
      // Direct messages have no channel id. Both save and restore keys end
      // up as "convId:" — they hit naturally without lastChannelByConversation.
      final c = ChatPanelController();
      c.selectedTextChannelId = null;

      final keyAtSave = c.cacheKeyFor('dmAlice');
      c.scrollPositions[keyAtSave] = 800.0;

      c.selectedTextChannelId = null; // unchanged for DMs
      final keyAtRestore = c.cacheKeyFor('dmAlice');

      expect(keyAtRestore, keyAtSave);
      expect(c.scrollPositions[keyAtRestore], 800.0);
    });

    test('evictScrollPositions drops oldest entries when over cap', () {
      final c = ChatPanelController();
      for (var i = 0; i < ChatPanelController.kMaxScrollPositions + 5; i++) {
        c.scrollPositions['conv$i:'] = i.toDouble();
      }
      c.evictScrollPositions();
      expect(c.scrollPositions.length, ChatPanelController.kMaxScrollPositions);
      // Oldest 5 should be gone.
      for (var i = 0; i < 5; i++) {
        expect(c.scrollPositions['conv$i:'], isNull);
      }
      // Newest entries still present.
      expect(
        c.scrollPositions['conv${ChatPanelController.kMaxScrollPositions + 4}:'],
        (ChatPanelController.kMaxScrollPositions + 4).toDouble(),
      );
    });
  });
}
