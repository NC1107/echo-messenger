import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debug_log_service.dart';

/// Callback type invoked when PTT should gate the microphone.
typedef SetCaptureEnabledCallback = void Function(bool enabled);

/// Installs a global [HardwareKeyboard] handler that gates the microphone
/// while the configured push-to-talk key is held.
///
/// Lifecycle:
///   - Call [start] after joining a voice room with PTT enabled.
///   - Call [stop] before leaving the room, or when PTT is disabled.
///   - Both methods are idempotent; excess calls are safe.
///
/// Key matching uses [LogicalKeyboardKey.keyId] serialised to a decimal
/// string, matching what the settings picker stores via
/// `event.logicalKey.keyId.toString()`.  The default binding is Space
/// (keyId 32 → `'32'`).
///
/// TODO(web): Web keyboard events arrive through a browser `keydown` /
/// `keyup` listener attached to the canvas element, not via
/// [HardwareKeyboard].  HardwareKeyboard.instance.addHandler is a no-op
/// on web (the handler is never called).  A web-specific PTT path — e.g.
/// attaching a `document.addEventListener('keydown', ...)` via `dart:js`
/// or `package:web` — is out of scope for this slice and should be
/// implemented separately.
class PushToTalkListener {
  PushToTalkListener({
    required String keyId,
    required SetCaptureEnabledCallback onSetCaptureEnabled,
  }) : _keyId = keyId,
       _onSetCaptureEnabled = onSetCaptureEnabled;

  final String _keyId;
  final SetCaptureEnabledCallback _onSetCaptureEnabled;

  bool _installed = false;

  /// Install the hardware-keyboard handler.
  ///
  /// No-op on web (see class-level TODO) and if already installed.
  void start() {
    if (kIsWeb) {
      DebugLogService.instance.log(
        LogLevel.info,
        'PushToTalkListener',
        'start() skipped on web — HardwareKeyboard PTT not supported (see TODO)',
      );
      return;
    }
    if (_installed) return;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _installed = true;
    DebugLogService.instance.log(
      LogLevel.info,
      'PushToTalkListener',
      'started — listening for keyId=$_keyId',
    );
  }

  /// Remove the hardware-keyboard handler.
  ///
  /// No-op on web and if not currently installed.
  void stop() {
    if (!_installed) return;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _installed = false;
    DebugLogService.instance.log(
      LogLevel.info,
      'PushToTalkListener',
      'stopped',
    );
  }

  /// Whether the keyboard handler is currently installed.
  bool get isRunning => _installed;

  bool _handleKeyEvent(KeyEvent event) {
    if (event.logicalKey.keyId.toString() != _keyId) return false;

    if (event is KeyDownEvent) {
      DebugLogService.instance.log(
        LogLevel.info,
        'PushToTalkListener',
        'PTT key down — enabling capture',
      );
      _onSetCaptureEnabled(true);
    } else if (event is KeyUpEvent) {
      DebugLogService.instance.log(
        LogLevel.info,
        'PushToTalkListener',
        'PTT key up — disabling capture',
      );
      _onSetCaptureEnabled(false);
    }

    // Return false so other handlers (e.g. the chat input bar's own
    // shortcut handler) still receive the event.
    return false;
  }
}
