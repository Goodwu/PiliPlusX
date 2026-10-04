enum LocalDiagnosticStartupResult {
  playerViewNotMounted,
  playbackRejected,
  started,
}

/// Initializes local playback without autoplay, then starts only after the
/// real player widget has mounted.
Future<LocalDiagnosticStartupResult> initializeAndStartLocalDiagnosticPlayback({
  required Future<void> Function({required bool autoplay}) initialize,
  required void Function() markPlayerReady,
  required Future<bool> Function() waitForPlayerViewMount,
  required Future<bool> Function() startPlayback,
}) async {
  await initialize(autoplay: false);
  markPlayerReady();
  if (!await waitForPlayerViewMount()) {
    return LocalDiagnosticStartupResult.playerViewNotMounted;
  }
  if (!await startPlayback()) {
    return LocalDiagnosticStartupResult.playbackRejected;
  }
  return LocalDiagnosticStartupResult.started;
}

/// Starts a local diagnostic only after its real player widget is mounted.
/// The current-source guard is checked before playback and after the native
/// play call, before asking the caller to refresh track metadata.
Future<bool> startLocalDiagnosticPlayback({
  required bool Function() isCurrent,
  required bool Function() isPlayerViewMounted,
  required Future<void> Function() play,
  required Future<void> Function() refreshTrackMetadata,
}) async {
  if (!isCurrent() || !isPlayerViewMounted()) return false;
  await play();
  if (!isCurrent()) return false;
  await refreshTrackMetadata();
  return isCurrent();
}
