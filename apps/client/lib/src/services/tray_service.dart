// Conditional export: desktop (dart:io available) uses the real implementation;
// web falls back to the no-op stub.
export 'tray_service_stub.dart' if (dart.library.io) 'tray_service_io.dart';
