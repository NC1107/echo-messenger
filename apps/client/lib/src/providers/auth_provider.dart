// Re-export shim. The auth notifier was split into a folder during the
// god-module refactor batch (see #770 for the umbrella migration tracker
// and #706 for the auth-specific @Riverpod migration). All ~73 existing
// `import '.../providers/auth_provider.dart';` call sites continue to work
// through this shim; once they migrate to the new path the shim can go.
export 'auth/auth_provider.dart';
