/// Non-web stub for the canvas test probe. All methods are no-ops so callers
/// compile cleanly on every non-web target without `if (kIsWeb)` guards.
library;

import '../models/canvas_models.dart';
import '../widgets/voice_lounge/lounge_canvas_strokes.dart' show ActiveStroke;

/// No-op probe on non-web targets.
class EchoTestProbe {
  EchoTestProbe._();

  /// Singleton. Exists on all platforms but is fully inert on non-web.
  static final EchoTestProbe instance = EchoTestProbe._();

  /// Register the canvas state accessors for the currently-active lounge.
  /// Called from the lounge widget on mount; no-op on non-web.
  // ignore: avoid_unused_parameters
  void register({
    required int Function() committedStrokeCount,
    required ActiveStroke? Function() activeStroke,
    required CanvasTool Function() selectedTool,
    required String Function() currentColor,
  }) {}

  /// Called from the lounge widget on dispose; no-op on non-web.
  void unregister() {}
}
