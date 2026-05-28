// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'encrypted_preview_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$showEncryptedPreviewsHash() =>
    r'fab54173cb13e9e490f739a9ae0733b79fd3b578';

/// Controls whether the sidebar conversation list and notification bodies
/// show decrypted plaintext previews (true, default) or always render
/// `[Encrypted]` for end-to-end encrypted messages (false).
///
/// Modelled on [GifPlayback] — a simple bool backed by SharedPreferences.
///
/// Copied from [ShowEncryptedPreviews].
@ProviderFor(ShowEncryptedPreviews)
final showEncryptedPreviewsProvider =
    NotifierProvider<ShowEncryptedPreviews, bool>.internal(
      ShowEncryptedPreviews.new,
      name: r'showEncryptedPreviewsProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$showEncryptedPreviewsHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ShowEncryptedPreviews = Notifier<bool>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
