import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which top-level view the voice lounge is in. Persisted at the
/// provider level so toggling fullscreen (which rebuilds the
/// HomeScreen layout column and remounts VoiceLoungeScreen at a
/// different Row index) doesn't snap the lounge back to spotlight.
enum VoiceLoungeView { spotlight, canvas }

final voiceLoungeViewModeProvider = StateProvider<VoiceLoungeView>(
  (ref) => VoiceLoungeView.spotlight,
);
