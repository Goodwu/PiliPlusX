typedef MpvPropertyReader = Future<String> Function(String name);

class SelectedVideoTrack {
  const SelectedVideoTrack({
    required this.id,
    required this.codec,
    required this.dolbyVisionProfile,
    required this.dolbyVisionLevel,
  });

  final String? id;
  final String? codec;
  final String? dolbyVisionProfile;
  final String? dolbyVisionLevel;
}

/// Reads only bounded metadata from mpv's selected video track. The caller
/// binds this read to one player and source generation; stale reads return
/// null and no property values are logged.
Future<SelectedVideoTrack?> readSelectedVideoTrack({
  required MpvPropertyReader readProperty,
  required bool Function() isCurrent,
  int maxTrackCount = 64,
}) async {
  if (!isCurrent()) return null;

  Future<String?> read(String name) async {
    if (!isCurrent()) return null;
    try {
      final value = (await readProperty(name)).trim();
      if (!isCurrent()) return null;
      return value.isEmpty ? null : value;
    } catch (_) {
      if (!isCurrent()) return null;
      return null;
    }
  }

  final countValue = await read('track-list/count');
  if (!isCurrent()) return null;
  final count = int.tryParse(countValue ?? '');
  if (count == null || count < 0 || count > maxTrackCount) return null;

  for (var index = 0; index < count; index++) {
    final prefix = 'track-list/$index';
    final type = await read('$prefix/type');
    final selected = await read('$prefix/selected');
    if (!isCurrent()) return null;
    if (type?.toLowerCase() != 'video' ||
        !const {'yes', 'true', '1'}.contains(selected?.toLowerCase())) {
      continue;
    }

    final id = await read('$prefix/id');
    final codec = await read('$prefix/codec');
    final profile = await read('$prefix/dolby-vision-profile');
    final level = await read('$prefix/dolby-vision-level');
    if (!isCurrent()) return null;
    return SelectedVideoTrack(
      id: id,
      codec: codec,
      dolbyVisionProfile: profile,
      dolbyVisionLevel: level,
    );
  }
  return null;
}
