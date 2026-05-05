// Re-export shim. The LiveKit voice notifier was split into a folder per
// the god-module refactor playbook in
// .claude/plans/generic-growing-bentley.md. Existing imports of this path
// keep working through this shim; once they migrate to the new path the
// shim can go.
export 'livekit_voice/livekit_voice_provider.dart';
