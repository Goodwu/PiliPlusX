import 'package:PiliPlus/pages/video/local_diagnostic/selected_video_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the selected video track by its reported index', () async {
    final properties = <String, String>{
      'track-list/count': '3',
      'track-list/0/type': 'audio',
      'track-list/0/selected': 'yes',
      'track-list/1/type': 'video',
      'track-list/1/selected': 'no',
      'track-list/2/type': 'video',
      'track-list/2/selected': 'yes',
      'track-list/2/id': '7',
      'track-list/2/codec': 'hevc',
      'track-list/2/dolby-vision-profile': '5',
      'track-list/2/dolby-vision-level': '9',
    };
    final queried = <String>[];

    final track = await readSelectedVideoTrack(
      readProperty: (name) async {
        queried.add(name);
        final value = properties[name];
        if (value == null) throw StateError('missing property');
        return value;
      },
      isCurrent: () => true,
    );

    expect(track?.id, '7');
    expect(track?.codec, 'hevc');
    expect(track?.dolbyVisionProfile, '5');
    expect(track?.dolbyVisionLevel, '9');
    expect(queried, isNot(contains('track-list')));
    expect(queried, contains('track-list/2/dolby-vision-profile'));
    expect(queried, isNot(contains('track-list/0/dolby-vision-profile')));
  });

  test('bounds the track count and never assumes track zero', () async {
    final queried = <String>[];
    final track = await readSelectedVideoTrack(
      readProperty: (name) async {
        queried.add(name);
        return '65';
      },
      isCurrent: () => true,
    );

    expect(track, isNull);
    expect(queried, ['track-list/count']);
  });

  test(
    'same-player source replacement stops subsequent property reads',
    () async {
      var current = true;
      final queried = <String>[];
      final track = await readSelectedVideoTrack(
        readProperty: (name) async {
          queried.add(name);
          if (name == 'track-list/count') return '1';
          if (name == 'track-list/0/type') return 'video';
          if (name == 'track-list/0/selected') {
            current = false;
            return 'yes';
          }
          return 'unexpected';
        },
        isCurrent: () => current,
      );

      expect(track, isNull);
      expect(queried, [
        'track-list/count',
        'track-list/0/type',
        'track-list/0/selected',
      ]);
    },
  );

  test('closing during property read stops later native calls', () async {
    var closing = false;
    final queried = <String>[];
    final track = await readSelectedVideoTrack(
      readProperty: (name) async {
        queried.add(name);
        if (name == 'track-list/count') {
          closing = true;
          return '1';
        }
        return 'unexpected';
      },
      isCurrent: () => !closing,
    );

    expect(track, isNull);
    expect(queried, ['track-list/count']);
  });
}
