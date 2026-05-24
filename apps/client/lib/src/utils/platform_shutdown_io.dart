import 'dart:io' show Platform, ProcessSignal, exit;

/// Registers a handler for `SIGTERM` on Linux and macOS.
///
/// When SIGTERM is received (e.g. from `kill -TERM <pid>` or systemd during
/// host shutdown) [onShutdown] is called synchronously, then the process exits
/// with code 0. No-op on Windows: `ProcessSignal.sigterm.watch()` is
/// unsupported there.
void registerSigtermHandler(void Function() onShutdown) {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  ProcessSignal.sigterm.watch().listen((_) {
    onShutdown();
    exit(0);
  });
}
