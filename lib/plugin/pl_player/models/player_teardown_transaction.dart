/// Outcome of one final Player teardown attempt.
enum PlayerTeardownResult {
  disposed,
  retainedForOutputRetry,
  retainedForPlayerRetry,
}

/// Enforces the output barrier before terminating a Player. The injected
/// callbacks keep the production teardown sequence directly behavior-testable.
class PlayerTeardownTransaction<P, O> {
  Future<PlayerTeardownResult> run({
    required P player,
    required O? output,
    required Future<void> Function(O output) disposeOutput,
    required Future<void> Function(P player) disposePlayer,
    required void Function({required O? output, required bool outputReleased})
    retainForRetry,
    required void Function(Object error, StackTrace stackTrace) onError,
    bool outputAlreadyReleased = false,
    int outputAttempts = 3,
    Duration retryDelay = const Duration(milliseconds: 200),
  }) async {
    if (outputAttempts <= 0) {
      throw ArgumentError.value(outputAttempts, 'outputAttempts');
    }
    var outputReleased = outputAlreadyReleased || output == null;
    if (!outputReleased) {
      for (var attempt = 1; attempt <= outputAttempts; attempt++) {
        try {
          await disposeOutput(output as O);
          outputReleased = true;
          break;
        } catch (error, stackTrace) {
          onError(error, stackTrace);
          if (attempt == outputAttempts) {
            retainForRetry(output: output, outputReleased: false);
            return PlayerTeardownResult.retainedForOutputRetry;
          }
          if (retryDelay > Duration.zero) {
            await Future<void>.delayed(retryDelay);
          }
        }
      }
    }

    try {
      await disposePlayer(player);
      return PlayerTeardownResult.disposed;
    } catch (error, stackTrace) {
      onError(error, stackTrace);
      retainForRetry(output: output, outputReleased: outputReleased);
      return PlayerTeardownResult.retainedForPlayerRetry;
    }
  }
}
