/// No-op stub for web and unsupported platforms.
/// SIGTERM is a POSIX signal not available on browsers or Windows.
void registerSigtermHandler(void Function() onShutdown) {}
