# iOS crash opening Voice & Video settings (build 500, v0.0.374)

**Status**: open. Breadcrumbs instrumented this PR (commit TBD); root cause not yet identified.

## What we know

- TestFlight build **500** (v0.0.374), the first build off the squash-merged audit batch (#967 + #968 + #969).
- iPhone 16,2 running **iOS 26.5 (23F77)**.
- User taps Settings → Voice & Video. App SIGABRTs immediately on the main thread.
- Exception: `NSInvalidArgumentException` — `-[__NSDictionaryM isEqualToString:]: unrecognized selector sent to instance 0x1479647c0`.
- Triggered from `_dispatch_main_queue_drain.cold.6` → `_dispatch_call_block_and_release` → two anonymous frames inside the main `Echo` binary (image offsets 1426676 and 1431300).
- WebRTC and AVAudioSession threads exist but are idle on `_pthread_cond_wait`/`poll`. The crash isn't in WebRTC C++ code; it's in our Objective-C / Swift layer.

## What that exception means

Native code somewhere did `[someValue isEqualToString:@"..."]` but `someValue` was an `NSMutableDictionary`, not an `NSString`. Common causes:

1. A method-channel response from a plugin returns a dict at a slot we cast to string.
2. A preferences read (NSUserDefaults / FlutterSecureStorage) returns the wrong type for an upgraded key.
3. KVC on a model object's @property where the property type was changed.

## Code path under suspicion

Settings → Voice & Video runs `_VoiceVideoSectionState._loadAudioDevices()` on first build (lib/src/screens/settings/notification_section.dart). That calls `webrtc.navigator.mediaDevices.enumerateDevices()` which hops to the `flutter_webrtc` plugin's iOS-side enumerate. The plugin parses returned device info into Dart `MediaDeviceInfo` objects.

`flutter_webrtc` is pinned at **1.4.1** (latest), originally to work around a separate iOS voice-lounge crash — see `apps/client/pubspec.yaml` dependency_overrides. Could be incompatible with iOS 26.5 in ways the 1.4.0 → 1.4.1 fix didn't anticipate.

## What landed in this PR

- `NSLocationWhenInUseUsageDescription` added to `Info.plist` to clear ITMS-90683 from the same upload. The location framework is linked transitively by `photo_manager` for EXIF; we never request location.
- Defensive breadcrumb logging via `DebugLogService.instance.log` around `_loadAudioDevices`:
  - "start (platform=…)"
  - "enumerateDevices returned N device(s)"
  - "applied X in / Y out / Z cam"
  - "_loadAudioDevices threw: \<error>\n\<stacktrace>" on any Dart-side throw, replacing the previous bare `catch (_) {}` swallow.

The breadcrumbs land in the on-disk debug log (per `app_lifecycle_logger.dart`). After the next crash on a TestFlight build that includes this PR, attaching the debug log to a bug report should at least show how far down the function got — distinguishing "crash before Dart-side init" vs "crash inside the iOS plugin response handler" vs "crash on apply-state".

## What this PR does NOT close

The actual crash. Root cause still requires:

1. A symbolicated dSYM for build 500 (the App Store Connect dSYM archive is the source of truth — `xcrun atos` against the .dSYM resolves the image offsets to source lines).
2. Reproduction on a debug build attached to Xcode so we see the full Objective-C backtrace with selector + receiver type.
3. If repro is consistent: a quick targeted change like dropping `_loadAudioDevices` entirely on iOS and using a hard-coded "Default Microphone / Camera" list until the plugin path can be fixed.

## Next-step playbook

When someone picks this up:

1. Download the build-500 dSYM from App Store Connect → Activity → Build 500 → Download dSYM.
2. `xcrun atos -arch arm64 -o Echo.app.dSYM/Contents/Resources/DWARF/Echo -l 0x100838000 0x1015c8e34 0x1015ca044` (substitute the actual load address and the two suspicious offsets from the crash report).
3. The two resolved source lines should point at either Swift code in `AppDelegate.swift` / `PipBridgePlugin.swift` or at compiled GeneratedPluginRegistrant code for one of the plugins.
4. If neither, drop into the plugin source for `flutter_webrtc 1.4.1` and search for `isEqualToString` patterns near `enumerateDevices` / `MediaDeviceInfo`.
