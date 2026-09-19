import 'dart:ui' show Offset;

/// Movement tolerance shared by the player tap and single-pointer gesture
/// recognizers.
///
/// The player uses this for tap-scale bookkeeping only. Direction ownership
/// must wait for [kPlayerDirectionQualificationSlop], so a small initial
/// horizontal wobble cannot lock a later vertical gesture into seek.
const double kPlayerTapSlop = 2.0;

/// Minimum accumulated movement before the player commits a single-pointer
/// direction. This mirrors Flutter's touch slop and is deliberately much
/// larger than [kPlayerTapSlop].
const double kPlayerDirectionQualificationSlop = 18.0;

/// Horizontal displacement must clearly dominate vertical drift before a
/// player-area gesture is treated as seek. Diagonal/mostly-vertical gestures
/// stay available to the vertical gesture and recommendation-list boundary.
const double kPlayerHorizontalSeekDominance = 3.0;

bool isPlayerHorizontalSeekDelta(Offset delta) {
  final dx = delta.dx.abs();
  final dy = delta.dy.abs();
  return dx > kPlayerHorizontalSeekDominance * dy;
}
