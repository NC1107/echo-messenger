const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// Short git SHA the build was produced from. CI plumbs `APP_COMMIT` via
/// `--dart-define`; local dev builds default to `local`.
const String appCommit = String.fromEnvironment(
  'APP_COMMIT',
  defaultValue: 'local',
);

/// ISO-8601 build timestamp. CI plumbs `APP_BUILD_TIME` via `--dart-define`;
/// local dev builds leave this empty, in which case the About screen hides
/// the row.
const String appBuildTime = String.fromEnvironment(
  'APP_BUILD_TIME',
  defaultValue: '',
);
