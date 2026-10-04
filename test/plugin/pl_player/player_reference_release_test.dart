import 'package:PiliPlus/plugin/pl_player/models/player_reference_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('non-final shared Player release only decrements its reference', () {
    final first = releasePlayerReference(2);
    expect(first.isFinal, isFalse);
    expect(first.remainingCount, 1);

    final last = releasePlayerReference(first.remainingCount);
    expect(last.isFinal, isTrue);
    expect(last.remainingCount, 0);
  });

  test('close-all forces final teardown regardless of reference count', () {
    final release = releasePlayerReference(2, forceFinal: true);
    expect(release.isFinal, isTrue);
    expect(release.remainingCount, 0);
  });
}
