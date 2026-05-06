import 'dart:io' show ProcessSignal, exit;

/// Registers a handler for `SIGTERM` on Linux and macOS.
///
/// When SIGTERM is received (e.g. from `kill -TERM <pid>` or systemd during
/// host shutdown) [onShutdown] is called synchronously, then the process exits
/// with code 0.
void registerSigtermHandler(void Function() onShutdown) {
  ProcessSignal.sigterm.watch().listen((_) {
    onShutdown();
    exit(0);
  });
}
