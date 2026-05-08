/// Centralized motion tokens for Echo's animation language.
///
/// Use these instead of inline `Duration(milliseconds: N)` and raw
/// `Curves.foo` references so tuning the feel of the app is a one-line
/// edit instead of a sweep across dozens of widgets.
///
/// Phase 0 of the UX roadmap (`docs/ux-roadmap.md`).
///
/// Naming is semantic, not numeric: a future contributor knows the
/// *intent* (`pulse`, `gentle`) without needing to remember the
/// concrete millisecond value.
library;

import 'package:flutter/animation.dart';

/// Durations for state transitions, hover feedback, and ambient motion.
///
/// Six tokens cover the full range Echo uses today.  Don't add a
/// seventh without justification — more granularity turns the API into
/// a lookup table.
class MotionDurations {
  MotionDurations._();

  /// Hover, micro-feedback, ripple acknowledgement.
  static const Duration instant = Duration(milliseconds: 80);

  /// Submenu open/close, tap response, dock highlight.
  static const Duration quick = Duration(milliseconds: 150);

  /// Banner slide, tile state change, default UI feedback.
  static const Duration standard = Duration(milliseconds: 200);

  /// Panel slide, dialog show/hide, mode switch.
  static const Duration expressive = Duration(milliseconds: 300);

  /// Presence transitions, status changes — slow enough to read as
  /// "something happened" without feeling sluggish.
  static const Duration gentle = Duration(milliseconds: 400);

  /// Ambient breathing — speaking ring pulse, idle indicators.
  /// Reserved for *continuous* motion, not one-shot transitions.
  static const Duration pulse = Duration(milliseconds: 700);
}

/// Curves for state transitions.
///
/// Three semantic curves cover entrance / exit / two-way motion, plus
/// one expressive overshoot for the rare cases that warrant a soft
/// "bounce" feel.  Don't add `Curves.bounceOut` or `Curves.elasticOut`
/// — premium ≠ cartoon (per the UX roadmap anti-goals).
class MotionCurves {
  MotionCurves._();

  /// Ease-out: starts fast, decelerates.  Use for things appearing on
  /// screen — tooltips, banners, panels sliding in.
  static const Curve entrance = Curves.easeOutCubic;

  /// Ease-in: starts slow, accelerates.  Use for things leaving —
  /// dismissed dialogs, banners sliding out.
  static const Curve exit = Curves.easeInCubic;

  /// Symmetric ease.  Use for in-place state changes (color shifts,
  /// border highlights) where there's no spatial origin or destination.
  static const Curve emphasis = Curves.easeInOutCubic;

  /// Soft overshoot.  Use only for celebratory or attention-pulling
  /// transitions — most state changes should use [emphasis] instead.
  /// Tuned so a 300ms expressive transition reads as "confident,"
  /// not "bouncy."
  static const Curve expressiveBounce = Cubic(0.34, 1.20, 0.64, 1.0);

  /// Sharp deceleration.  Reserved for drag-release physics where the
  /// user's gesture sets the initial velocity.
  static const Curve decelerate = Curves.decelerate;
}
