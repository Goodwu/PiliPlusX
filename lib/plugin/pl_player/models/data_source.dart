import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  DataSource({
    required this.videoSource,
    required this.audioSource,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
  });
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}

/// An explicitly selected local file used by the opt-in macOS playback
/// diagnostic. Unlike [FileSource], this path is not part of a Bilibili
/// download entry and has no companion audio file.
class DirectFileSource extends DataSource {
  DirectFileSource(String path) : super(videoSource: path, audioSource: null);
}

/// True only for the explicit local-diagnostic path; ordinary files and
/// network sources must retain their normal playback side effects.
bool isLocalDiagnosticSource(DataSource source) => source is DirectFileSource;
