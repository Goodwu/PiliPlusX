import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS teardown releases output before Player.dispose', () {
    final source = File('lib/plugin/pl_player/controller.dart')
        .readAsStringSync();
    final helper = source.substring(
      source.indexOf('Future<void> _disposePlayerAfterVideoOutput('),
      source.indexOf(
        '\n  static void updatePlayCount()',
      ),
    );

    expect(
      helper,
      contains('PlayerTeardownTransaction<Player, VideoController>()'),
      reason: 'production close path must use the behavior-tested barrier',
    );
  });

  test('all shared-player close paths use the teardown barrier', () {
    final source = File('lib/plugin/pl_player/controller.dart')
        .readAsStringSync();
    expect(source, contains('_schedulePlayerTeardown();'));
    expect(source, isNot(contains('\n        player.dispose();')));
    expect(source, contains('class _InitializedVideoPlayer'));
    expect(
      source,
      contains('initialized.lease.publishIfCurrent('),
      reason: 'the final shared publication gate owns transfer or disposal',
    );
    expect(
      source,
      contains('PlayerInitializationTransaction<'),
      reason:
          'probe/output lifecycle uses the injectable production transaction',
    );
    expect(
      source,
      contains('final candidate = await transaction.run('),
      reason: 'source replacement completion follows the tested transaction',
    );
    expect(
      source,
      contains(
        'final Map<Player, _BlockedPlayerTeardown> _blockedTeardowns',
      ),
    );
    expect(source, contains('_scheduleBlockedTeardownRetry();'));
  });
}
