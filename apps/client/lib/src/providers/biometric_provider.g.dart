// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'biometric_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$biometricHash() => r'67c498962f61c6ab6f9994b667f14206fb883d1e';

/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// Singleton lifetime via `keepAlive: true` because the lock-session timer
/// (`_lastAuthTime` + `_lockTimeout`) lives on the notifier instance and
/// the auto-dispose default would lose it whenever no widget is watching.
///
/// Copied from [Biometric].
@ProviderFor(Biometric)
final biometricProvider = NotifierProvider<Biometric, BiometricState>.internal(
  Biometric.new,
  name: r'biometricProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$biometricHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$Biometric = Notifier<BiometricState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
