module.exports = {
  extends: ['@commitlint/config-conventional'],
  // Skip Copilot scaffolding commits and merge/bot artifacts that arrive
  // via squash/merge from PR branches we don't control.
  ignores: [
    (msg) => /^Initial plan/i.test(msg),
    (msg) => /^merge:/i.test(msg),
    (msg) => /^Merge pull request /.test(msg),
    (msg) => /^Merge branch /.test(msg),
    (msg) => /^Merge remote-tracking branch /.test(msg),
    (msg) => /^Bump /.test(msg),
  ],
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'docs', 'style', 'refactor', 'perf',
      'test', 'build', 'ci', 'chore', 'revert', 'security',
    ]],
    'scope-enum': [1, 'always', [
      'core', 'server', 'client', 'infra', 'proto', 'crypto', 'ci', 'deps',
      'a11y', 'security',
    ]],
    'subject-case': [2, 'always', 'lower-case'],
    'subject-max-length': [2, 'always', 72],
  },
};
