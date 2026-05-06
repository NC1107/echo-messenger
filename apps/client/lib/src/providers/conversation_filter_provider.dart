import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/conversation.dart';
import '../utils/fuzzy_score.dart';
import 'auth_provider.dart';
import 'conversations_provider.dart';

part 'conversation_filter_provider.g.dart';

/// Which conversation type to show (all / DM-only / group-only).
enum ConversationFilterType { all, dms, groups }

/// Current search query entered by the user. Empty string = no search.
@riverpod
class ConversationSearchQuery extends _$ConversationSearchQuery {
  @override
  String build() => '';

  /// Replace the current query.
  void set(String value) => state = value;
}

/// Active type filter (All / DMs / Groups).
@riverpod
class ConversationFilterTypeNotifier extends _$ConversationFilterTypeNotifier {
  @override
  ConversationFilterType build() => ConversationFilterType.all;

  /// Replace the current filter selection.
  void set(ConversationFilterType value) => state = value;
}

/// Pinned conversation IDs. Loaded from SharedPreferences + merged with
/// server-side isPinned flag during [ConversationPanel] initialisation.
@riverpod
class PinnedConversationIds extends _$PinnedConversationIds {
  @override
  Set<String> build() => const {};

  /// Replace the entire pinned-ID set (callers compute the new set
  /// elsewhere and hand it in whole).
  void set(Set<String> value) => state = value;
}

/// Derived, memoized list of conversations ready for the list view.
///
/// Applies in order:
/// 1. Type filter (all / DMs / groups).
/// 2. Fuzzy-search filter + relevance sort (only when query is non-empty).
/// 3. Pin-first sort: pinned conversations appear before unpinned; each group
///    is independently sorted by last-message timestamp descending.
///
/// Riverpod only re-runs this provider when one of its watched dependencies
/// actually changes, so the O(n log n) work is never duplicated across widget
/// rebuilds triggered by unrelated state (e.g. WS status toggling, theme
/// changes, or cursor blink).
@riverpod
List<Conversation> sortedConversations(Ref ref) {
  final conversations = ref.watch(
    conversationsProvider.select((s) => s.conversations),
  );
  final query = ref.watch(conversationSearchQueryProvider);
  final filterType = ref.watch(conversationFilterTypeNotifierProvider);
  final pinnedIds = ref.watch(pinnedConversationIdsProvider);
  final myUserId = ref.watch(authProvider.select((s) => s.userId)) ?? '';

  // 1. Type filter.
  Iterable<Conversation> result = switch (filterType) {
    ConversationFilterType.dms => conversations.where((c) => !c.isGroup),
    ConversationFilterType.groups => conversations.where((c) => c.isGroup),
    ConversationFilterType.all => conversations,
  };

  // 2. Fuzzy-search filter + relevance sort.
  if (query.isNotEmpty) {
    final scored = <({Conversation conv, double score})>[];
    for (final conv in result) {
      final name = conv.displayName(myUserId);
      final lastMsg = conv.lastMessage ?? '';
      final nameScore = fuzzyScore(query, name);
      final msgScore = fuzzyScore(query, lastMsg);
      final score = (nameScore * 2 + msgScore) / 3;
      if (score > 0.2) scored.add((conv: conv, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => e.conv).toList();
  }

  // 3. Pin-first sort (only when not in search mode).
  final pinned = <Conversation>[];
  final unpinned = <Conversation>[];
  for (final conv in result) {
    if (pinnedIds.contains(conv.id) || conv.isPinned) {
      pinned.add(conv);
    } else {
      unpinned.add(conv);
    }
  }

  int byTimestamp(Conversation a, Conversation b) {
    final ta = a.lastMessageTimestamp ?? '';
    final tb = b.lastMessageTimestamp ?? '';
    return tb.compareTo(ta);
  }

  pinned.sort(byTimestamp);
  unpinned.sort(byTimestamp);
  return [...pinned, ...unpinned];
}

/// Backwards-compat alias: callers historically referred to the filter-type
/// notifier as `conversationFilterTypeProvider`. The codegen suffixes the
/// generated provider with the class name (`Notifier`), so the alias keeps
/// the call-site name short.
final conversationFilterTypeProvider = conversationFilterTypeNotifierProvider;
