// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'theme_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$appThemeHash() => r'60b5c020ddee994117998e93b703c866e519e6c8';

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
String _$uIDensityNotifierHash() => r'b63be7192710cd7e4854b0c246f87c7a2016742b';

/// See also [UIDensityNotifier].
@ProviderFor(UIDensityNotifier)
final uIDensityNotifierProvider =
    NotifierProvider<UIDensityNotifier, UIDensity>.internal(
      UIDensityNotifier.new,
      name: r'uIDensityNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$uIDensityNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$UIDensityNotifier = Notifier<UIDensity>;
String _$customColorsHash() => r'8c29d77cdeb45748e1dd87e93287d132534582b8';

/// See also [CustomColors].
@ProviderFor(CustomColors)
final customColorsProvider =
    NotifierProvider<CustomColors, CustomColorsState>.internal(
      CustomColors.new,
      name: r'customColorsProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$customColorsHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$CustomColors = Notifier<CustomColorsState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
