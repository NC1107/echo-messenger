// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'conversation_filter_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$sortedConversationsHash() =>
    r'3c2f7abd3bb6c8dbad4790e32f9433ad5784d4d7';

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
///
/// Copied from [sortedConversations].
@ProviderFor(sortedConversations)
final sortedConversationsProvider =
    AutoDisposeProvider<List<Conversation>>.internal(
      sortedConversations,
      name: r'sortedConversationsProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$sortedConversationsHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SortedConversationsRef = AutoDisposeProviderRef<List<Conversation>>;
String _$conversationSearchQueryHash() =>
    r'8a9f2f0919aad6c794545fd04589b303bc074c85';

/// Current search query entered by the user. Empty string = no search.
///
/// Copied from [ConversationSearchQuery].
@ProviderFor(ConversationSearchQuery)
final conversationSearchQueryProvider =
    AutoDisposeNotifierProvider<ConversationSearchQuery, String>.internal(
      ConversationSearchQuery.new,
      name: r'conversationSearchQueryProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$conversationSearchQueryHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ConversationSearchQuery = AutoDisposeNotifier<String>;
String _$conversationFilterTypeNotifierHash() =>
    r'49d6e2fd6d3de37d4a7d7ef2a48981f3246917c6';

/// Active type filter (All / DMs / Groups).
///
/// Copied from [ConversationFilterTypeNotifier].
@ProviderFor(ConversationFilterTypeNotifier)
final conversationFilterTypeNotifierProvider =
    AutoDisposeNotifierProvider<
      ConversationFilterTypeNotifier,
      ConversationFilterType
    >.internal(
      ConversationFilterTypeNotifier.new,
      name: r'conversationFilterTypeNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$conversationFilterTypeNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ConversationFilterTypeNotifier =
    AutoDisposeNotifier<ConversationFilterType>;
String _$pinnedConversationIdsHash() =>
    r'bfcfe89866a917cfbc89e941e740ed3fa7c89407';

/// Pinned conversation IDs. Loaded from SharedPreferences + merged with
/// server-side isPinned flag during [ConversationPanel] initialisation.
///
/// Copied from [PinnedConversationIds].
@ProviderFor(PinnedConversationIds)
final pinnedConversationIdsProvider =
    AutoDisposeNotifierProvider<PinnedConversationIds, Set<String>>.internal(
      PinnedConversationIds.new,
      name: r'pinnedConversationIdsProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$pinnedConversationIdsHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$PinnedConversationIds = AutoDisposeNotifier<Set<String>>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
