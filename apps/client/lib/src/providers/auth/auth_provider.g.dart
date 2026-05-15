// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$authNotifierHash() => r'595afa498e5ed1cbff07368ae09f2447eb4a71ab';

/// Authentication state notifier.
///
/// File layout (god-module split — see #770 / #785 for the broader
/// refactor backlog):
/// - This file: facade — state class, notifier shell, public lifecycle
///   methods (`register` / `login` / `logout` / `setPresenceStatus`),
///   shared private fields the parts read from.
/// - `auth_token_storage.dart` (part): Hive + SharedPreferences I/O,
///   one-shot legacy migration.
/// - `auth_token_refresh.dart` (part): auto-login, refresh flow, the
///   401-retrying `authenticatedRequest` helper.
///
/// Copied from [AuthNotifier].
@ProviderFor(AuthNotifier)
final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>.internal(
  AuthNotifier.new,
  name: r'authNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$authNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$AuthNotifier = Notifier<AuthState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
