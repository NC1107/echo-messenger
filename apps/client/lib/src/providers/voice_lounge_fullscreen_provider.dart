import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Global flag toggled when the voice lounge is in fullscreen-immersive mode.
/// Read by HomeScreen layouts (to hide AppTitleBar, sidebar, members panel)
/// and by VoiceLoungeScreen (to hide its own header / badge). The dock stays
/// visible regardless.
final voiceLoungeFullscreenProvider = StateProvider<bool>((ref) => false);
