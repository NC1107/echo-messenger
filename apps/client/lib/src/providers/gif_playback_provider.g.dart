// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'gif_playback_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$gifPlaybackHash() => r'fd304afc6963d832d34add4f41bf8af55f062e53';

/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// `keepAlive: true` matches the singleton lifetime of the original
/// `StateNotifierProvider`. Lifecycle-observer detach happens through
/// `ref.onDispose` instead of an overridden `dispose()`.
///
/// Copied from [GifPlayback].
@ProviderFor(GifPlayback)
final gifPlaybackProvider =
    NotifierProvider<GifPlayback, GifPlaybackState>.internal(
      GifPlayback.new,
      name: r'gifPlaybackProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$gifPlaybackHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$GifPlayback = Notifier<GifPlaybackState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
