class PlayerReferenceReleaseDecision {
  const PlayerReferenceReleaseDecision({
    required this.remainingCount,
    required this.isFinal,
  });

  final int remainingCount;
  final bool isFinal;
}

/// Decides whether a shared Player release is non-final or tears down the
/// shared owner. Kept independent of page/UI state so refcount behavior can be
/// covered without constructing a platform Player.
PlayerReferenceReleaseDecision releasePlayerReference(
  int currentCount, {
  bool forceFinal = false,
}) {
  if (!forceFinal && currentCount > 1) {
    return PlayerReferenceReleaseDecision(
      remainingCount: currentCount - 1,
      isFinal: false,
    );
  }
  return const PlayerReferenceReleaseDecision(remainingCount: 0, isFinal: true);
}
