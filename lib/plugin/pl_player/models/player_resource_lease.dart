import 'dart:async';

/// Tracks an unpublished Player/output pair while asynchronous initialization
/// is in progress. The owner must either [transfer] the pair after publishing
/// it, or [release] it on stale completion/failure.
///
/// This small type has no media-kit dependency so initialization ownership can
/// be exercised with deterministic fake handles in unit tests.
class PlayerResourceLease<O> {
  O? _output;
  bool _released = false;
  bool _transferred = false;
  Future<void>? _releaseFuture;

  O? get output => _output;
  bool get released => _released;
  bool get transferred => _transferred;

  /// Runs initialization while the lease owns every resource acquired by the
  /// operation. Any thrown error releases the unpublished pair before it is
  /// rethrown; a successful operation must explicitly [transfer] or [release]
  /// the lease before returning.
  Future<T> run<T>(
    Future<T> Function() operation, {
    required Future<void> Function(O? output) disposePair,
  }) async {
    try {
      return await operation();
    } catch (_) {
      await release(disposePair);
      rethrow;
    }
  }

  /// Performs the synchronous shared-state publication only when the owning
  /// source is still current. Callers put pair assignment, listener binding and
  /// [transfer] in this one callback so no await separates those operations.
  Future<bool> publishIfCurrent({
    required bool Function() isCurrent,
    required void Function() publish,
    required void Function() rollback,
    required Future<void> Function(O? output) disposePair,
  }) async {
    if (!isCurrent()) {
      await release(disposePair);
      return false;
    }
    try {
      publish();
      transfer();
      return true;
    } catch (_) {
      // Revoke any partially published shared state synchronously before the
      // asynchronous native teardown starts.
      try {
        rollback();
      } catch (_) {
        // Cleanup must still reach the output barrier if rollback itself
        // encounters a synchronous listener/cancellation error.
      }
      await release(disposePair);
      rethrow;
    }
  }

  void attachOutput(O output) {
    if (_released || _transferred) {
      throw StateError('Cannot attach output after Player ownership ended');
    }
    _output = output;
  }

  void transfer() {
    if (_released) throw StateError('Cannot transfer released Player');
    _transferred = true;
  }

  Future<void> release(Future<void> Function(O? output) disposePair) {
    if (_released || _transferred) return Future<void>.value();
    final inFlight = _releaseFuture;
    if (inFlight != null) return inFlight;
    final attempt = Completer<void>();
    _releaseFuture = attempt.future;
    () async {
      try {
        await disposePair(_output);
        _released = true;
        _output = null;
        attempt.complete();
      } catch (error, stackTrace) {
        // Preserve the pair and allow a later explicit retry. All concurrent
        // callers of this attempt observe the same failure.
        _releaseFuture = null;
        attempt.completeError(error, stackTrace);
      }
    }();
    return attempt.future;
  }
}
