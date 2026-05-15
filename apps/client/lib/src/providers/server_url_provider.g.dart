// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_url_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$knownServersNotifierHash() =>
    r'14eb30c5e66d9f7d12a7e88d369b28a73c462db5';

/// Companion provider exposing the persisted list of known servers. Updated
/// in lockstep with [serverUrlProvider] by [ServerUrlNotifier.switchTo],
/// [addKnownServer], [forget], and [recordLastUsername].
///
/// Migrated from `StateNotifier` to `@riverpod` codegen (#770, 2026-05-14).
///
/// Copied from [KnownServersNotifier].
@ProviderFor(KnownServersNotifier)
final knownServersNotifierProvider =
    NotifierProvider<KnownServersNotifier, List<KnownServer>>.internal(
      KnownServersNotifier.new,
      name: r'knownServersNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$knownServersNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$KnownServersNotifier = Notifier<List<KnownServer>>;
String _$serverUrlNotifierHash() => r'eabbd849ccc64e8b6997fafb8f33cace1b1d8c3f';

/// Riverpod provider holding the active server URL. Backwards-compatible:
/// state is still a `String`, so the ~100 existing call sites continue to
/// work unchanged. Known-server metadata lives in [knownServersProvider].
///
/// Migrated from `StateNotifier` to `@riverpod` codegen (#770, 2026-05-14).
///
/// Copied from [ServerUrlNotifier].
@ProviderFor(ServerUrlNotifier)
final serverUrlNotifierProvider =
    NotifierProvider<ServerUrlNotifier, String>.internal(
      ServerUrlNotifier.new,
      name: r'serverUrlNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$serverUrlNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ServerUrlNotifier = Notifier<String>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
