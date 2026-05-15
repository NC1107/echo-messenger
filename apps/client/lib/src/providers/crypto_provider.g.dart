// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'crypto_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$cryptoNotifierHash() => r'44d8eb500679de4b3a4f4f293a348dcef1a3b549';

/// Migrated from `StateNotifier` to `@riverpod`-annotated `Notifier`
/// (audit 2026-05-14, Riverpod modernization slice — #770). The exported
/// provider symbol `cryptoProvider` is preserved via the auto-generated
/// `cryptoNotifierProvider` aliased below so the ~30 existing call sites do
/// not change.
///
/// Copied from [CryptoNotifier].
@ProviderFor(CryptoNotifier)
final cryptoNotifierProvider =
    NotifierProvider<CryptoNotifier, CryptoState>.internal(
      CryptoNotifier.new,
      name: r'cryptoNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$cryptoNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$CryptoNotifier = Notifier<CryptoState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
