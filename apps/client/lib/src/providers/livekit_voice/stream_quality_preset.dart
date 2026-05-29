/// Named stream-quality presets for camera and screen-share video tracks.
///
/// The mapping is the single authoritative source used by
/// [ScreenShareSubmenuStandalone] to populate the quality picker, by
/// [VoiceSettings] to persist the chosen preset, and by the quality badge
/// in the voice dock to derive the displayed label.
library;

/// Named quality tier for video encoding.
enum StreamQuality {
  /// LiveKit adaptive stream manages quality automatically.
  auto,

  /// SD — 480p-class encoding, minimal bandwidth.
  sd,

  /// HD — 720p-class encoding, default on join.
  hd,

  /// Full HD — 1080p-class encoding.
  fullHd,

  /// Ultra — 4K-class encoding for high-resolution screen shares.
  ultra,
}

/// Encoding parameters that correspond to a [StreamQuality] tier.
class StreamQualityParams {
  /// Maximum video bitrate in bits per second.
  final int bitrate;

  /// Maximum frame rate in frames per second.
  final int fps;

  const StreamQualityParams({required this.bitrate, required this.fps});
}

/// Maps each [StreamQuality] tier to its encoding parameters.
///
/// `auto` has no fixed params — the caller must check [StreamQuality.auto]
/// before reading from this map and engage LiveKit adaptive stream instead.
const Map<StreamQuality, StreamQualityParams> kStreamQualityParams = {
  StreamQuality.sd: StreamQualityParams(bitrate: 500000, fps: 30),
  StreamQuality.hd: StreamQualityParams(bitrate: 1500000, fps: 30),
  StreamQuality.fullHd: StreamQualityParams(bitrate: 2500000, fps: 30),
  StreamQuality.ultra: StreamQualityParams(bitrate: 5000000, fps: 30),
};

/// Human-readable label shown in the quality picker and dock badge.
const Map<StreamQuality, String> kStreamQualityLabel = {
  StreamQuality.auto: 'Auto',
  StreamQuality.sd: 'SD',
  StreamQuality.hd: 'HD',
  StreamQuality.fullHd: 'Full HD',
  StreamQuality.ultra: '4K Ultra',
};

/// Short label used for the compact dock badge (max ~6 chars).
const Map<StreamQuality, String> kStreamQualityShortLabel = {
  StreamQuality.auto: 'Auto',
  StreamQuality.sd: 'SD',
  StreamQuality.hd: 'HD',
  StreamQuality.fullHd: 'FHD',
  StreamQuality.ultra: '4K',
};

/// Parse a persisted string key back to a [StreamQuality].
///
/// Falls back to [StreamQuality.auto] for unknown values so old prefs
/// don't crash after an upgrade.
StreamQuality streamQualityFromString(String value) {
  return StreamQuality.values.firstWhere(
    (q) => q.name == value,
    orElse: () => StreamQuality.auto,
  );
}
