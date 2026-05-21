// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'participated_threads_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$participatedThreadsHash() =>
    r'c03f5160dcf6bde5de3759b642080c5cbd5d0808';

/// Fetches and caches the list of threads the authenticated user has
/// participated in. Lives for the app session (keepAlive) so the sidebar
/// badge stays warm; call [load] / [refresh] on demand.
///
/// WS reactivity is wired at the screen / sidebar level via
/// `websocketProvider`'s reply-bearing message stream — when a
/// `MessageRelayed`-style event arrives with a non-null `reply_to_id`,
/// listeners call [refresh] to pick up the new thread row.
///
/// Copied from [ParticipatedThreads].
@ProviderFor(ParticipatedThreads)
final participatedThreadsProvider =
    NotifierProvider<ParticipatedThreads, ParticipatedThreadsState>.internal(
      ParticipatedThreads.new,
      name: r'participatedThreadsProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$participatedThreadsHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ParticipatedThreads = Notifier<ParticipatedThreadsState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
