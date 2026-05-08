/// Phase 3c of `docs/ux-roadmap.md`: voice-lounge layer hierarchy.
///
/// The room guides attention automatically based on who is speaking.
/// Tiles/pucks render one of three attention states; the parent
/// computes the cross-participant context (`anyoneElseSpeaking`) and
/// passes the resulting [ParticipantAttention] down to each leaf.
library;

/// Attention level of a single voice-lounge participant relative to
/// the rest of the room.
enum ParticipantAttention {
  /// This participant is currently speaking.  Visually elevated.
  speaking,

  /// Someone else is speaking and this participant is not.
  /// Visually receded so the speaker stands out.
  faded,

  /// Nobody is speaking.  Default rest state, full opacity, no
  /// elevation.
  idle,
}

/// Map a participant's speaking state plus the room's broader
/// "is someone else speaking" signal into a [ParticipantAttention].
///
/// The two booleans are deliberately decoupled so the parent can
/// compute the room-level state once per build and pass the same
/// `anyoneElseSpeaking` value down to every tile, avoiding O(N²)
/// recomputation per participant.
ParticipantAttention attentionFor({
  required bool isSpeaking,
  required bool anyoneElseSpeaking,
}) {
  if (isSpeaking) return ParticipantAttention.speaking;
  if (anyoneElseSpeaking) return ParticipantAttention.faded;
  return ParticipantAttention.idle;
}
