/// Web implementation of the canvas e2e test probe.
///
/// Installs `window.__echoTestProbe__` in debug + profile builds so
/// Playwright audit specs can assert canvas committed-stroke counts and
/// active-stroke metadata without introspecting Riverpod internals.
///
/// The exposed API is intentionally minimal and read-only:
/// ```js
/// window.__echoTestProbe__.canvasCommittedStrokeCount()  // => number
/// window.__echoTestProbe__.canvasActiveStroke()          // => object | null
/// window.__echoTestProbe__.canvasSelectedTool()          // => string
/// window.__echoTestProbe__.canvasCurrentColor()          // => string
/// ```
///
/// Cited from: tests/e2e/output/mobile-audit-report.md (Known gaps section).
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:web/web.dart' as web;

import '../models/canvas_models.dart';
import '../widgets/voice_lounge/lounge_canvas_strokes.dart' show ActiveStroke;

// ---------------------------------------------------------------------------
// Probe implementation
// ---------------------------------------------------------------------------

/// Singleton that manages the `window.__echoTestProbe__` installation.
class EchoTestProbe {
  EchoTestProbe._();

  static final EchoTestProbe instance = EchoTestProbe._();

  int Function()? _committedStrokeCount;
  ActiveStroke? Function()? _activeStroke;
  CanvasTool Function()? _selectedTool;
  String Function()? _currentColor;
  bool _installed = false;

  /// Register canvas-state accessors from the active lounge widget.
  /// Called on mount; installs the probe object if not already present.
  void register({
    required int Function() committedStrokeCount,
    required ActiveStroke? Function() activeStroke,
    required CanvasTool Function() selectedTool,
    required String Function() currentColor,
  }) {
    if (kReleaseMode) return;
    _committedStrokeCount = committedStrokeCount;
    _activeStroke = activeStroke;
    _selectedTool = selectedTool;
    _currentColor = currentColor;
    if (!_installed) {
      _installProbeObject();
      _forceEnableSemantics();
      _installed = true;
    }
  }

  /// Force-enable Flutter Web's accessibility tree so Playwright's
  /// `getByLabel(...)` can resolve the `Semantics(label:)` strings on
  /// canvas tool icons. Flutter normally enables this lazily when a
  /// screen reader is detected; the audit never triggers that path.
  ///
  /// Active only in debug+profile builds; never in release.
  void _forceEnableSemantics() {
    if (kReleaseMode) return;
    try {
      // The semantics-enabled flag lives on Flutter's engine bootstrap
      // object. Path varies slightly across Flutter versions; we try
      // each known location and ignore failures.
      final flutter = web.window.getProperty('flutter'.toJS);
      if (flutter != null) {
        final app = (flutter as JSObject).getProperty('app'.toJS);
        if (app != null) {
          final setter = (app as JSObject).getProperty(
            'setSemanticsEnabled'.toJS,
          );
          if (setter != null) {
            (setter as JSFunction).callAsFunction(app, true.toJS);
          }
        }
      }
    } catch (_) {
      // Best effort — ignore.
    }
  }

  /// Clear accessors when the lounge disposes.
  void unregister() {
    _committedStrokeCount = null;
    _activeStroke = null;
    _selectedTool = null;
    _currentColor = null;
  }

  // Installs `window.__echoTestProbe__` with getter-style JS functions.
  // Each function closes over the Dart closures registered by [register] so
  // the spec always reads the most recent registered provider.
  void _installProbeObject() {
    final probe = JSObject();

    probe.setProperty(
      'canvasCommittedStrokeCount'.toJS,
      (() {
        final count = _committedStrokeCount?.call() ?? 0;
        return count.toJS;
      }).toJS,
    );

    probe.setProperty(
      'canvasActiveStroke'.toJS,
      (() {
        final stroke = _activeStroke?.call();
        if (stroke == null) return null.jsify();
        final obj = JSObject();
        obj.setProperty('points'.toJS, stroke.points.length.toJS);
        obj.setProperty('tool'.toJS, stroke.kind.name.toJS);
        obj.setProperty('color'.toJS, stroke.color.toJS);
        obj.setProperty('width'.toJS, stroke.width.toJS);
        return obj;
      }).toJS,
    );

    probe.setProperty(
      'canvasSelectedTool'.toJS,
      (() {
        final tool = _selectedTool?.call() ?? CanvasTool.none;
        return tool.name.toJS;
      }).toJS,
    );

    probe.setProperty(
      'canvasCurrentColor'.toJS,
      (() {
        final hex = _currentColor?.call() ?? '#FFFFFF';
        return hex.toJS;
      }).toJS,
    );

    web.window.setProperty('__echoTestProbe__'.toJS, probe);
  }
}
