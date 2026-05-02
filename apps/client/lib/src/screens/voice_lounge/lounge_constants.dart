/// Shared constants for the voice lounge screen and its sibling widgets.
///
/// These were originally private to `voice_lounge_screen.dart`. They are now
/// shared between the orchestrator screen and the extracted dock submenu
/// widgets, so they live in a small dedicated file imported by both.
library;

/// Tile key used to identify the local screen-share stream.
const String kScreenshareLocal = 'screenshare-local';

/// Which dock submenu is currently open.
enum DockSubmenu { mic, camera, screenShare, draw }

/// Screen sharing is supported on all platforms. iOS uses a ReplayKit
/// Broadcast Upload Extension (EchoBroadcast target).
const bool kSupportsScreenShare = true;
