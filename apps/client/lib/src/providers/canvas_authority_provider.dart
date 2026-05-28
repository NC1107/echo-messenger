import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'canvas_authority_provider.g.dart';

/// Tracks the canvas authority device for a given voice-lounge channel.
///
/// Authority is the device_id (int) of the user's device that currently holds
/// the write lock for canvas events. When null, nobody has claimed yet and any
/// device may write. When set, only the named device's sends reach the server
/// (others are silently dropped server-side; the client skips the send early).
///
/// Updated by inbound `canvas_authority_changed` WS events dispatched from
/// [WsMessageHandler._handleCanvasAuthorityChanged].
///
/// See docs/voice-lounge/03-multi-device.md — Option C decision.
@Riverpod(keepAlive: true)
class CanvasAuthorityNotifier extends _$CanvasAuthorityNotifier {
  @override
  int? build(String channelId) => null;

  /// Called when a `canvas_authority_changed` WS event arrives for this
  /// channel. Stores the device that now holds the write lock.
  void setAuthority(int deviceId) {
    state = deviceId;
  }

  /// Called when the local user leaves the lounge; resets authority so a
  /// fresh join starts clean.
  void clear() {
    state = null;
  }
}

/// Convenience read-only provider: the authority device for [channelId].
/// Null means unclaimed (any device may write).
final canvasAuthorityProvider = canvasAuthorityNotifierProvider;
