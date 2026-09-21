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

    expect(helper, contains('await platform.disposeForRebuild();'));
    expect(helper, contains('await player.dispose();'));
    expect(
      helper.indexOf('await platform.disposeForRebuild();'),
      lessThan(helper.indexOf('await player.dispose();')),
    );
    expect(
      helper,
      contains('preserving player for safe teardown'),
      reason:
          'an output-release failure must not fall through to libmpv destroy',
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
      contains(
        'await _disposePlayerAfterVideoOutput(player, initialized.video);',
      ),
      reason: 'a stale init must release its own immutable player/output pair',
    );
    expect(
      source,
      contains(
        'await _disposePlayerAfterVideoOutput(player, nextVideoController);',
      ),
      reason: 'a stale local output must release before its Player terminates',
    );
    expect(source, contains('for (var attempt = 1; attempt <= 3; attempt++)'));
    expect(
      source,
      contains('final Map<Player, VideoController> _blockedTeardowns'),
    );
    expect(source, contains('_scheduleBlockedTeardownRetry();'));
  });
}
