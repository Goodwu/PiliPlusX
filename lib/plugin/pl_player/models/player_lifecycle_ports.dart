import 'package:PiliPlus/plugin/pl_player/hdr_platform.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' hide HdrCapabilities;

/// Narrow native boundary used by PlPlayerController's real lifecycle paths.
///
/// The production adapter below preserves the same media-kit calls and
/// arguments. Tests can replace only native creation/probe/disposal while
/// exercising the controller's source generations, publication, open gate,
/// rebuild queue, reference counting, and teardown code.
class PlayerLifecyclePorts {
  const PlayerLifecyclePorts({
    required this.createPlayer,
    required this.probeHdr,
    required this.createOutput,
    required this.displayChanges,
    required this.disposeOutput,
    required this.disposePlayer,
  });

  final Future<Player> Function(PlayerConfiguration configuration) createPlayer;
  final Future<HdrCapabilities> Function() probeHdr;
  final Future<VideoController> Function(
    Player player,
    VideoControllerConfiguration configuration,
  )
  createOutput;
  final Stream<void> Function() displayChanges;
  final Future<void> Function(VideoController output) disposeOutput;
  final Future<void> Function(Player player) disposePlayer;

  factory PlayerLifecyclePorts.production() => PlayerLifecyclePorts(
    createPlayer: (configuration) =>
        Player.create(configuration: configuration),
    probeHdr: HdrPlatform.probe,
    createOutput: (player, configuration) => VideoController.create(
      player,
      configuration: configuration,
    ),
    displayChanges: () => HdrPlatform.displayChanges,
    disposeOutput: (output) async {
      final platform = await output.platform.future;
      await platform.disposeForRebuild();
    },
    disposePlayer: (player) => player.dispose(),
  );
}
