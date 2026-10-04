import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/pages/video/local_diagnostic/policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'diagnostic route arguments are inert when the build flag is absent',
    () {
      expect(localVideoDiagnosticBuildEnabled, isFalse);
      expect(
        isLocalVideoDiagnosticArgs({'localVideoDiagnostic': true}),
        isFalse,
      );
    },
  );

  test('diagnostic playback never persists local progress', () {
    expect(
      shouldPersistLocalPlaybackProgress(localDiagnostic: true),
      isFalse,
    );
    expect(
      shouldPersistLocalPlaybackProgress(localDiagnostic: false),
      isTrue,
    );
  });

  test('current-source predicate rejects replaced source and closing page', () {
    final source = DirectFileSource('/tmp/a.mp4');
    final replacement = DirectFileSource('/tmp/b.mp4');
    final player = Object();

    expect(
      isCurrentDiagnosticSource(
        source: source,
        player: player,
        currentSource: source,
        currentPlayer: player,
        closing: false,
      ),
      isTrue,
    );
    expect(
      isCurrentDiagnosticSource(
        source: source,
        player: player,
        currentSource: replacement,
        currentPlayer: player,
        closing: false,
      ),
      isFalse,
    );
    expect(
      isCurrentDiagnosticSource(
        source: source,
        player: player,
        currentSource: source,
        currentPlayer: player,
        closing: true,
      ),
      isFalse,
    );
  });
}
