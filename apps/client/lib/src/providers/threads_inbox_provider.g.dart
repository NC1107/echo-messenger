// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'threads_inbox_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$threadsInboxHash() => r'1af78c14b9077d9faafc265edd8edb0535088eac';

/// See also [ThreadsInbox].
@ProviderFor(ThreadsInbox)
final threadsInboxProvider =
    NotifierProvider<ThreadsInbox, ThreadsInboxState>.internal(
      ThreadsInbox.new,
      name: r'threadsInboxProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$threadsInboxHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ThreadsInbox = Notifier<ThreadsInboxState>;
String _$unreadThreadCountHash() => r'abb352917474884c76b879a6e964dda44a2ff326';

/// Aggregated unread-threads number for the nav-rail badge. Polled on
/// app focus + after each markRead.
///
/// Copied from [UnreadThreadCount].
@ProviderFor(UnreadThreadCount)
final unreadThreadCountProvider =
    NotifierProvider<UnreadThreadCount, int>.internal(
      UnreadThreadCount.new,
      name: r'unreadThreadCountProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$unreadThreadCountHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$UnreadThreadCount = Notifier<int>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
