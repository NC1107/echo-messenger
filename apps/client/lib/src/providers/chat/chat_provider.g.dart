// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$chatHash() => r'84aa3b0eb11f10a0d209ed0d7bc8051f1a327874';

/// Owns the per-conversation message list, the optimistic-send pipeline
/// (with 15s retry timers + reply-count bookkeeping), and the public API
/// the rest of the app reaches through `chatProvider`.
///
/// File layout (god-module split tracker #770):
/// - This file: notifier facade — timer map, `build`, hot-path send /
///   confirm / retry, status updates, reply state, `clear`.
/// - `chat_state.dart` (part): the immutable [ChatState] data class
///   plus placeholder-content constants and the `withMessage` /
///   `withSyncRestored` / `withSignatureFailureCleared` transitions.
/// - `chat_reactions.dart` (part): add/remove reaction.
/// - `chat_history.dart` (part): cache load, paginated REST fetch, 1:1
///   + group decrypt pipeline.
/// - `chat_edits.dart` (part): edits, soft-deletes, read sweeps, pin
///   toggles, forward helper.
/// - `chat_recovery.dart` (part): banner-driven recovery actions
///   (reset session, refresh group key, dismiss signature failure)
///   and the system-event injector.
///
/// Copied from [Chat].
@ProviderFor(Chat)
final chatProvider = NotifierProvider<Chat, ChatState>.internal(
  Chat.new,
  name: r'chatProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$chatHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$Chat = Notifier<ChatState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
