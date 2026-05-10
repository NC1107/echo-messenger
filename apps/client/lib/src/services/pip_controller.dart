import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'debug_log_service.dart';

/// Bridges the Flutter UI to native Picture-in-Picture for the screen-share
/// scenario.  Voice + screen share remains active when the user backgrounds
/// the app; the OS displays a PiP window with just the remote screen share
/// track until they return.
///
/// Wiring contract:
///
///   - When a remote participant publishes a screen-share video track,
///     [LiveKitVoiceNotifier] calls [enable] with the track's natural
///     dimensions.  The native side stores the aspect and auto-enters
///     PiP on `onUserLeaveHint` (Android) / `applicationWillResignActive`
///     (iOS, in Slice 4).
///   - When the screen share ends or the user leaves voice, [disable] is
///     called so backgrounding goes back to the no-PiP path.
///   - The native side reports PiP mode changes via `onPipChanged`
///     callbacks; the controller exposes them on [isInPipNotifier].
///
/// On platforms without a PiP path (web, desktop), every method is a no-op.
class PipController {
  PipController._() {
    if (_isMobile) {
      _channel.setMethodCallHandler(_handleMethodCall);
    }
  }
  static final PipController instance = PipController._();

  static const _channel = MethodChannel('us.echomessenger/pip');

  /// Test-only override: when true, every method behaves as if running on
  /// a mobile device.  Lets unit tests exercise the platform-channel
  /// surface without an Android / iOS host.
  @visibleForTesting
  static bool debugTreatAsMobile = false;

  static bool get _isMobile {
    if (debugTreatAsMobile) return true;
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// True while the system is rendering the activity in PiP mode.  Backed
  /// by a [ValueNotifier] so widgets can rebuild without subscribing to a
  /// stream — see [pipModeProvider].
  final ValueNotifier<bool> isInPipNotifier = ValueNotifier<bool>(false);

  bool _eligible = false;
  int _lastWidth = 0;
  int _lastHeight = 0;

  /// Whether PiP eligibility is currently set.  When false, the native
  /// activity will not enter PiP on home/lock.
  bool get isEligible => _eligible;

  /// Enable PiP on background with the given source dimensions.  Repeated
  /// calls with new dimensions update the aspect ratio without re-entering
  /// PiP, which lets the native side track resolution changes mid-call.
  ///
  /// Width / height should come from the WebRTC track; values <= 0 fall
  /// back to a 16:9 default so we never push an invalid Rational.
  Future<void> enable({required int width, required int height}) async {
    if (!_isMobile) return;
    final w = width > 0 ? width : 1280;
    final h = height > 0 ? height : 720;
    if (_eligible && _lastWidth == w && _lastHeight == h) return;
    try {
      await _channel.invokeMethod('setEligible', {'width': w, 'height': h});
      _eligible = true;
      _lastWidth = w;
      _lastHeight = h;
      _log('PiP eligibility enabled (${w}x$h)');
    } catch (e) {
      _log('Failed to enable PiP eligibility: $e', error: true);
    }
  }

  /// Disable PiP eligibility.  Call when the screen share ends or the user
  /// leaves voice — keeps the activity from dropping into PiP for an
  /// audio-only call where there's nothing to render.
  Future<void> disable() async {
    if (!_isMobile || !_eligible) return;
    try {
      await _channel.invokeMethod('setEligible', {'width': 0, 'height': 0});
      _eligible = false;
      _lastWidth = 0;
      _lastHeight = 0;
      _log('PiP eligibility cleared');
    } catch (e) {
      _log('Failed to clear PiP eligibility: $e', error: true);
    }
  }

  /// Programmatically request PiP entry.  Useful for an "Enter PiP" button;
  /// the home-press path uses [enable] alone since the OS triggers entry
  /// from `onUserLeaveHint` automatically once eligible.
  ///
  /// Returns true when the OS accepted the request (always false off
  /// mobile or when no track is registered).
  Future<bool> enterPip() async {
    if (!_isMobile || !_eligible) return false;
    try {
      final result = await _channel.invokeMethod<bool>('enterPip');
      return result ?? false;
    } catch (e) {
      _log('Failed to request PiP entry: $e', error: true);
      return false;
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onPipChanged') return null;
    final args = (call.arguments as Map?) ?? const {};
    final inPip = (args['inPip'] as bool?) ?? false;
    if (isInPipNotifier.value != inPip) {
      isInPipNotifier.value = inPip;
      _log('PiP mode changed: $inPip');
    }
    return null;
  }

  void _log(String message, {bool error = false}) {
    debugPrint('[PipController] $message');
    DebugLogService.instance.log(
      error ? LogLevel.error : LogLevel.info,
      'PipController',
      message,
    );
  }

  /// Test-only: reset internal flags so a fresh test can reuse the singleton.
  @visibleForTesting
  void resetForTesting() {
    _eligible = false;
    _lastWidth = 0;
    _lastHeight = 0;
    isInPipNotifier.value = false;
  }
}

/// Riverpod provider exposing the current PiP mode.  Widgets (e.g. the
/// voice lounge) can `ref.watch(pipModeProvider)` to render a stripped-down
/// layout while the system is showing PiP.
final pipModeProvider = ChangeNotifierProvider<_PipModeNotifier>(
  (ref) => _PipModeNotifier(PipController.instance.isInPipNotifier),
);

class _PipModeNotifier extends ChangeNotifier {
  _PipModeNotifier(this._source) {
    _source.addListener(_onChange);
  }

  final ValueNotifier<bool> _source;

  bool get inPip => _source.value;

  void _onChange() => notifyListeners();

  @override
  void dispose() {
    _source.removeListener(_onChange);
    super.dispose();
  }
}
