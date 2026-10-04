import 'package:PiliPlus/plugin/pl_player/models/player_resource_lease.dart';

/// A Player plus an output candidate that is still owned by its initialization
/// transaction. The caller must transfer the lease only after publishing the
/// pair into the live controller.
class PlayerInitializationCandidate<P, O, C> {
  const PlayerInitializationCandidate({
    required this.player,
    required this.output,
    required this.capabilities,
    required this.lease,
  });

  final P player;
  final O output;
  final C capabilities;
  final PlayerResourceLease<O> lease;
}

/// Runs the probe/output part of controller initialization against injectable
/// platform boundaries. This is production-used by PlPlayerController and
/// keeps stale-source and exception cleanup identical to the tested behavior.
class PlayerInitializationTransaction<P, O, C> {
  Future<PlayerInitializationCandidate<P, O, C>?> run({
    required P player,
    required PlayerResourceLease<O> lease,
    required bool Function() isCurrent,
    required Future<C> Function() probe,
    required Future<O> Function(C capabilities) createOutput,
    required Future<void> Function(O? output) disposePair,
  }) async {
    try {
      final capabilities = await probe();
      if (!isCurrent()) {
        await lease.release(disposePair);
        return null;
      }

      final output = await createOutput(capabilities);
      lease.attachOutput(output);
      if (!isCurrent()) {
        await lease.release(disposePair);
        return null;
      }

      return PlayerInitializationCandidate<P, O, C>(
        player: player,
        output: output,
        capabilities: capabilities,
        lease: lease,
      );
    } catch (_) {
      final stale = !isCurrent();
      await lease.release(disposePair);
      if (stale) return null;
      rethrow;
    }
  }
}
