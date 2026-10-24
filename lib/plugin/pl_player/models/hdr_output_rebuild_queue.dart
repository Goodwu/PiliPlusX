/// Coalesces native-output rebuild requests while a rebuild is running.
///
/// A null pending value means there is no queued request. In particular,
/// `false` is a real request to rebuild onto Texture and must be retained.
class HdrOutputRebuildQueue {
  bool _inFlight = false;
  bool? _queuedNativeSurface;

  bool get inFlight => _inFlight;

  bool? request(bool nativeSurface) {
    if (_inFlight) {
      _queuedNativeSurface = nativeSurface;
      return null;
    }
    _inFlight = true;
    return nativeSurface;
  }

  /// Completes the current operation and returns one valid pending request.
  /// The latest queued value wins. A request is discarded when its owner is
  /// no longer current, and each pending request is consumed exactly once.
  bool? complete({required bool Function() mayReplay}) {
    _inFlight = false;
    final queuedNativeSurface = _queuedNativeSurface;
    _queuedNativeSurface = null;
    if (queuedNativeSurface == null || !mayReplay()) return null;
    _inFlight = true;
    return queuedNativeSurface;
  }
}
