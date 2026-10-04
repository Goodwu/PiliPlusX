import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';

const bool localVideoDiagnosticBuildEnabled = bool.fromEnvironment(
  'PILIPLUS_LOCAL_VIDEO_DIAGNOSTICS',
  defaultValue: false,
);

bool isLocalVideoDiagnosticArgs(Map<dynamic, dynamic> args) =>
    localVideoDiagnosticBuildEnabled && args['localVideoDiagnostic'] == true;

bool shouldPersistLocalPlaybackProgress({required bool localDiagnostic}) =>
    !localDiagnostic;

bool isCurrentDiagnosticSource({
  required DirectFileSource source,
  required Object player,
  required DataSource currentSource,
  required Object? currentPlayer,
  required bool closing,
}) =>
    !closing &&
    identical(source, currentSource) &&
    identical(player, currentPlayer);
