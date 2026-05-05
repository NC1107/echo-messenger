// Re-export shim. The auth notifier was split into a folder per the
// god-module refactor playbook (see RIVERPOD_MIGRATION.md and
// .claude/plans/generic-growing-bentley.md). All ~73 existing
// `import '.../providers/auth_provider.dart';` call sites continue to work
// through this shim; once they migrate to the new path the shim can go.
export 'auth/auth_provider.dart';
