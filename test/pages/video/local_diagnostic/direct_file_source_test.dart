import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'direct diagnostic source preserves the picked path and has no audio',
    () {
      const path = '/Users/test/Movies/Mystery Box Dolby Vision Profile 5.mp4';
      final source = DirectFileSource(path);

      expect(source.videoSource, path);
      expect(source.audioSource, isNull);
      expect(source, isNot(isA<FileSource>()));
    },
  );

  test(
    'only the current DirectFileSource carries diagnostic heartbeat scope',
    () {
      final sequence = <DataSource>[
        DirectFileSource('/tmp/picked.mp4'),
        FileSource(
          dir: '/tmp',
          isMp4: true,
          hasDashAudio: false,
          typeTag: 'ordinary',
        ),
        NetworkSource(
          videoSource: 'https://example.invalid/video.m3u8',
          audioSource: null,
        ),
      ];

      // PlPlayerController assigns this predicate at every source boundary, so
      // switching away from the diagnostic source clears its heartbeat guard.
      expect(sequence.map(isLocalDiagnosticSource), [true, false, false]);
    },
  );
}
