/// Unit tests for [WindowStateService] — Wayland position skip + multi-monitor
/// validation.
///
/// These tests verify the three new behaviours introduced to fix the Linux
/// off-screen restore regression (#linux-wayland-window):
///
///   1. On Wayland, [WindowStateService.save] must NOT persist x/y
///      (`window.x` / `window.y`) because [windowManager.getPosition] returns
///      compositor-local coordinates that are meaningless on the next launch.
///
///   2. On Wayland, [WindowStateService.restore] must NOT call
///      `windowManager.setPosition` (i.e. no `setBounds` call with the saved
///      x/y coordinates).
///
///   3. After a `setPosition` call on X11/Windows, if the actual window
///      position drifted more than 200 px from the requested position, the
///      service falls back to `center()`. We detect `center()` being invoked
///      by watching for a `getCursorScreenPoint` call on the screen_retriever
///      channel (that call is only made by `calcWindowPosition`, which is only
///      called from `windowManager.center()`).
///
/// Channel notes:
/// - window_manager uses `MethodChannel('window_manager')`. getSize/getPosition
///   go through `getBounds`; setSize/setPosition go through `setBounds`.
/// - screen_retriever uses
///   `MethodChannel('dev.leanflutter.plugins/screen_retriever')`.
///   `getAllDisplays` result wraps the list under a `'displays'` key.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/services/window_state_service.dart';

// ---------------------------------------------------------------------------
// Channel references
// ---------------------------------------------------------------------------

const _wmChannel = MethodChannel('window_manager');
const _srChannel =
    MethodChannel('dev.leanflutter.plugins/screen_retriever');

// ---------------------------------------------------------------------------
// Call-tracking lists (reset in setUp)
// ---------------------------------------------------------------------------

final List<MethodCall> _wmCalls = [];
final List<MethodCall> _srCalls = [];

// ---------------------------------------------------------------------------
// Default fake display maps (match Display.fromJson expectations)
// ---------------------------------------------------------------------------

const Map<String, Object?> _fakeDisplayMap = {
  'id': 'display-0',
  'name': 'DP-1',
  'scaleFactor': 1.0,
  'size': {'width': 1920.0, 'height': 1080.0},
  'visiblePosition': {'dx': 0.0, 'dy': 0.0},
  'visibleSize': {'width': 1920.0, 'height': 1040.0},
};

const Map<String, Object?> _fakeSecondaryDisplayMap = {
  'id': 'display-1',
  'name': 'DP-2',
  'scaleFactor': 1.0,
  'size': {'width': 1920.0, 'height': 1080.0},
  'visiblePosition': {'dx': 1920.0, 'dy': 0.0},
  'visibleSize': {'width': 1920.0, 'height': 1040.0},
};

// ---------------------------------------------------------------------------
// Mock installers
// ---------------------------------------------------------------------------

/// Install a fake handler on the `window_manager` channel.
///
/// [boundsResult] is returned for every `getBounds` call (used by both
/// `getSize` and `getPosition`). Override to simulate compositor drift.
void _installWmMock({
  Map<String, Object?> boundsResult = const {
    'x': 0.0,
    'y': 0.0,
    'width': 1280.0,
    'height': 720.0,
  },
}) {
  _wmCalls.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_wmChannel, (call) async {
        _wmCalls.add(call);
        if (call.method == 'getBounds') return boundsResult;
        return null;
      });
}

/// Install a fake handler on the `screen_retriever` channel.
///
/// [displays] is used for `getAllDisplays` (wrapped under `'displays'` key)
/// and for `getPrimaryDisplay` (first element). A cursor point well inside
/// the primary display is returned for `getCursorScreenPoint`.
void _installSrMock({
  List<Map<String, Object?>> displays = const [_fakeDisplayMap],
}) {
  _srCalls.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_srChannel, (call) async {
        _srCalls.add(call);
        switch (call.method) {
          case 'getAllDisplays':
            return {'displays': displays};
          case 'getPrimaryDisplay':
            return displays.isNotEmpty ? displays.first : _fakeDisplayMap;
          case 'getCursorScreenPoint':
            return {'dx': 960.0, 'dy': 540.0};
          default:
            return null;
        }
      });
}

void _removeMocks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_wmChannel, null);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_srChannel, null);
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

/// True when a `setBounds` call was made with position exactly (x, y).
///
/// `setPosition(Offset(x, y))` → `setBounds` arguments contain 'x' == x
/// AND 'y' == y. `setSize` calls contain 'width'/'height' but no 'x'/'y'.
bool _setPositionWasCalledWith(double x, double y) {
  return _wmCalls.any((c) {
    if (c.method != 'setBounds') return false;
    final args = c.arguments as Map?;
    if (args == null) return false;
    return args['x'] == x && args['y'] == y;
  });
}

/// True when `center()` was invoked.
///
/// `center()` → `calcWindowPosition()` → `screenRetriever.getCursorScreenPoint()`
/// That is the only call path that hits `getCursorScreenPoint`, so it serves
/// as a reliable marker for center() being called.
bool get _centerWasCalled =>
    _srCalls.any((c) => c.method == 'getCursorScreenPoint');

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _installWmMock();
    _installSrMock();
  });

  tearDown(() {
    WindowStateService.debugOverrideIsWayland = null;
    _removeMocks();
  });

  // ── 1. Wayland detection ────────────────────────────────────────────────────

  group('isWaylandSession via debugOverrideIsWayland', () {
    test('returns true when override is set to true', () {
      WindowStateService.debugOverrideIsWayland = true;
      expect(WindowStateService.isWaylandSession, isTrue);
    });

    test('returns false when override is set to false', () {
      WindowStateService.debugOverrideIsWayland = false;
      expect(WindowStateService.isWaylandSession, isFalse);
    });
  });

  // ── 2. save() on Wayland ────────────────────────────────────────────────────

  group('save() on Wayland', () {
    setUp(() => WindowStateService.debugOverrideIsWayland = true);

    test('does NOT persist window.x or window.y', () async {
      await WindowStateService.save();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('window.x'), isNull,
          reason: 'window.x must not be saved on Wayland');
      expect(prefs.getDouble('window.y'), isNull,
          reason: 'window.y must not be saved on Wayland');
    });

    test('still persists window.width and window.height', () async {
      await WindowStateService.save();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('window.width'), isNotNull,
          reason: 'window.width must still be saved on Wayland');
      expect(prefs.getDouble('window.height'), isNotNull,
          reason: 'window.height must still be saved on Wayland');
    });
  });

  // ── 3. save() on X11 ────────────────────────────────────────────────────────

  group('save() on X11 / non-Wayland', () {
    setUp(() => WindowStateService.debugOverrideIsWayland = false);

    test('persists window.x and window.y from getBounds', () async {
      _installWmMock(
        boundsResult: {
          'x': 150.0,
          'y': 200.0,
          'width': 1280.0,
          'height': 720.0,
        },
      );

      await WindowStateService.save();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('window.x'), 150.0);
      expect(prefs.getDouble('window.y'), 200.0);
    });
  });

  // ── 4. restore() on Wayland ─────────────────────────────────────────────────

  group('restore() on Wayland', () {
    setUp(() {
      WindowStateService.debugOverrideIsWayland = true;
      SharedPreferences.setMockInitialValues({
        'window.width': 1280.0,
        'window.height': 720.0,
        'window.x': 200.0,
        'window.y': 200.0,
      });
    });

    test('does NOT call setPosition with the saved coordinates', () async {
      await WindowStateService.restore();

      expect(
        _setPositionWasCalledWith(200.0, 200.0),
        isFalse,
        reason: 'setPosition must not be called with saved coords on Wayland',
      );
    });

    test('calls center() instead of restoring the saved position', () async {
      await WindowStateService.restore();

      expect(
        _centerWasCalled,
        isTrue,
        reason:
            'center() must be called on Wayland since setPosition is a no-op',
      );
    });
  });

  // ── 5. restore() on X11 with valid coords ───────────────────────────────────

  group('restore() on X11 / non-Wayland, valid saved position', () {
    setUp(() {
      WindowStateService.debugOverrideIsWayland = false;
      SharedPreferences.setMockInitialValues({
        'window.width': 1280.0,
        'window.height': 720.0,
        'window.x': 300.0,
        'window.y': 300.0,
      });
      // Compositor honours the position — no drift.
      _installWmMock(
        boundsResult: {
          'x': 300.0,
          'y': 300.0,
          'width': 1280.0,
          'height': 720.0,
        },
      );
    });

    test('calls setPosition with the saved coordinates', () async {
      await WindowStateService.restore();

      expect(
        _setPositionWasCalledWith(300.0, 300.0),
        isTrue,
        reason: 'setPosition must be called with saved coords when on-screen',
      );
    });

    test('does not call center() on X11 when position was honoured', () async {
      await WindowStateService.restore();

      expect(
        _centerWasCalled,
        isFalse,
        reason:
            'center() must not be called when compositor honoured position',
      );
    });
  });

  // ── 6. restore() drift-check ────────────────────────────────────────────────

  group('restore() drift-check fallback on X11', () {
    setUp(() {
      WindowStateService.debugOverrideIsWayland = false;
      SharedPreferences.setMockInitialValues({
        'window.width': 1280.0,
        'window.height': 720.0,
        'window.x': 300.0,
        'window.y': 300.0,
      });
    });

    test('calls center() when compositor drifted > 200 px', () async {
      // Simulate: compositor ignored setPosition and left window at (5, 5).
      _installWmMock(
        boundsResult: {'x': 5.0, 'y': 5.0, 'width': 1280.0, 'height': 720.0},
      );

      await WindowStateService.restore();

      // setPosition(300, 300) must have been attempted.
      expect(_setPositionWasCalledWith(300.0, 300.0), isTrue);
      // After detecting the > 200 px drift, center() must be called.
      expect(
        _centerWasCalled,
        isTrue,
        reason: 'center() must be called when the compositor drifted > 200 px',
      );
    });

    test('does NOT call center() when drift is within tolerance', () async {
      // Compositor placed the window at (310, 305) — within 200 px of (300, 300).
      _installWmMock(
        boundsResult: {
          'x': 310.0,
          'y': 305.0,
          'width': 1280.0,
          'height': 720.0,
        },
      );

      await WindowStateService.restore();

      expect(_setPositionWasCalledWith(300.0, 300.0), isTrue);
      expect(
        _centerWasCalled,
        isFalse,
        reason: 'center() must NOT be called when drift is within tolerance',
      );
    });
  });

  // ── 7. multi-monitor _isOnScreen awareness ──────────────────────────────────

  group('restore() multi-monitor position validation', () {
    setUp(() => WindowStateService.debugOverrideIsWayland = false);

    test('restores position when coord is on secondary monitor', () async {
      // Saved position is on the second monitor (right of 1920-wide primary).
      SharedPreferences.setMockInitialValues({
        'window.width': 1280.0,
        'window.height': 720.0,
        'window.x': 2000.0,
        'window.y': 100.0,
      });
      // Compositor places the window exactly where requested.
      _installWmMock(
        boundsResult: {
          'x': 2000.0,
          'y': 100.0,
          'width': 1280.0,
          'height': 720.0,
        },
      );
      // Two monitors: primary 0..1920, secondary 1920..3840.
      _installSrMock(displays: [_fakeDisplayMap, _fakeSecondaryDisplayMap]);

      await WindowStateService.restore();

      expect(
        _setPositionWasCalledWith(2000.0, 100.0),
        isTrue,
        reason: 'setPosition must be called for a coord valid on the secondary',
      );
      expect(_centerWasCalled, isFalse);
    });

    test('falls back to center() when coords are off all screens', () async {
      // Saved position is clearly off all monitors.
      SharedPreferences.setMockInitialValues({
        'window.width': 1280.0,
        'window.height': 720.0,
        'window.x': 5000.0,
        'window.y': 5000.0,
      });
      _installWmMock();
      // Only the 1920×1080 primary display — (5000, 5000) is off-screen.
      _installSrMock(displays: [_fakeDisplayMap]);

      await WindowStateService.restore();

      expect(
        _setPositionWasCalledWith(5000.0, 5000.0),
        isFalse,
        reason: 'setPosition must not be called for off-screen coords',
      );
      expect(
        _centerWasCalled,
        isTrue,
        reason:
            'center() must be called when saved coords are off all displays',
      );
    });
  });
}
