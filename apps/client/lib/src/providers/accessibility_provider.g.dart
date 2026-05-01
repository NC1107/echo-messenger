// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'accessibility_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$accessibilityHash() => r'1d490869342809e9bcd9c32d2e786afe404d2be5';

/// Migrated from `StateNotifier` to `@riverpod`-annotated `Notifier` (audit
/// 2026-04-30, Riverpod modernization slice). The exported provider symbol
/// `accessibilityProvider` is preserved so the ~12 existing call sites do
/// not change.
///
/// `keepAlive: true` matches the original `StateNotifierProvider` semantics
/// -- the singleton lives for the whole app session so we don't re-run
/// `_load()` (a SharedPreferences read) every time a widget re-watches.
///
/// Copied from [Accessibility].
@ProviderFor(Accessibility)
final accessibilityProvider =
    NotifierProvider<Accessibility, AccessibilityState>.internal(
      Accessibility.new,
      name: r'accessibilityProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$accessibilityHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$Accessibility = Notifier<AccessibilityState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
