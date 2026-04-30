// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'theme_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$appThemeHash() => r'ded610d070442924290afae9634d3b5792b06845';

/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// Class is named `AppTheme` (not `Theme`) to avoid colliding with Flutter's
/// `Theme` widget in importing files; `themeProvider` is preserved via an
/// alias below so call sites are unchanged.
///
/// Copied from [AppTheme].
@ProviderFor(AppTheme)
final appThemeProvider = NotifierProvider<AppTheme, AppThemeSelection>.internal(
  AppTheme.new,
  name: r'appThemeProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$appThemeHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$AppTheme = Notifier<AppThemeSelection>;
String _$messageLayoutNotifierHash() =>
    r'bcd897f43c8b6b3f3657d9d2ade5c33b997357c8';

/// See also [MessageLayoutNotifier].
@ProviderFor(MessageLayoutNotifier)
final messageLayoutNotifierProvider =
    NotifierProvider<MessageLayoutNotifier, MessageLayout>.internal(
      MessageLayoutNotifier.new,
      name: r'messageLayoutNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$messageLayoutNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$MessageLayoutNotifier = Notifier<MessageLayout>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
