// Re-export shim. The chat notifier was split into a folder during the
// god-module refactor batch (see #770 for the umbrella migration tracker).
// All existing `import '.../providers/chat_provider.dart';` call sites
// continue to work through this shim; once they migrate to the new path
// the shim can go.
export 'chat/chat_provider.dart';
