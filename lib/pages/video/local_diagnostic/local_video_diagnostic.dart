import 'dart:io';
import 'dart:async';

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models_new/video/video_detail/stat_detail.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/local_diagnostic/playback.dart';
import 'package:PiliPlus/pages/video/local_diagnostic/selected_video_track.dart';
import 'package:PiliPlus/pages/video/local_diagnostic/policy.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart'
    show TimeBatteryMixin;
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/bottom_control.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/play_pause_btn.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:media_kit/media_kit.dart' show VideoParams;

class LocalVideoDiagnosticEntryPage extends StatefulWidget {
  const LocalVideoDiagnosticEntryPage({super.key});

  @override
  State<LocalVideoDiagnosticEntryPage> createState() =>
      _LocalVideoDiagnosticEntryPageState();
}

class _LocalVideoDiagnosticEntryPageState
    extends State<LocalVideoDiagnosticEntryPage> {
  bool _picking = false;
  String? _message;

  Future<void> _pickVideo() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _message = null;
    });
    try {
      final result = await FilePicker.pickFile(type: FileType.video);
      if (result == null) return;
      final filePath = result.path;
      if (filePath == null || filePath.isEmpty) {
        setState(() => _message = '文件选择器没有返回可直接播放的路径。');
        return;
      }

      final handle = await File(filePath).open(mode: FileMode.read);
      await handle.close();
      if (!mounted) return;
      final heroTag =
          'local-diagnostic-${DateTime.now().microsecondsSinceEpoch}';
      await Get.to<void>(
        () => const LocalVideoDiagnosticPlayerPage(),
        arguments: {
          'localVideoDiagnostic': true,
          'localVideoPath': filePath,
          'localVideoName': result.name,
          'heroTag': heroTag,
          'sourceType': SourceType.file,
        },
      );
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = '无法访问所选文件：${error.code}');
    } on FileSystemException {
      if (mounted) setState(() => _message = '无法读取所选文件。');
    } catch (_) {
      if (mounted) setState(() => _message = '无法打开文件选择器。');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地视频诊断')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '此入口仅用于当前构建中的本地播放诊断。视频使用标准播放器控件和输出生命周期；不读取或写入 B 站播放记录、下载条目或评论。',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _picking ? null : _pickVideo,
                icon: const Icon(Icons.video_file_outlined),
                label: Text(_picking ? '正在选择…' : '选择本地视频'),
              ),
              if (_message case final message?) ...[
                const SizedBox(height: 12),
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'macOS 沙盒仅允许访问本次文件选择器授权的文件；访问权不跨应用进程保存。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class LocalVideoDiagnosticPlayerPage extends StatefulWidget {
  const LocalVideoDiagnosticPlayerPage({super.key});

  @override
  State<LocalVideoDiagnosticPlayerPage> createState() =>
      _LocalVideoDiagnosticPlayerPageState();
}

class _LocalVideoDiagnosticPlayerPageState
    extends State<LocalVideoDiagnosticPlayerPage> {
  VideoDetailController? _videoDetailController;
  LocalDiagnosticIntroController? _introController;
  String _trackSummary = '等待真实视频轨道参数';
  String? _error;
  bool _closing = false;
  bool _allowPop = false;
  bool _playerReady = false;
  bool _disposeRequested = false;
  final GlobalKey _playerViewKey = GlobalKey();
  StreamSubscription? _videoParamsSubscription;
  String _videoDimensions = '尺寸未知';

  @override
  void initState() {
    super.initState();
    if (!localVideoDiagnosticBuildEnabled || !Platform.isMacOS) {
      _error = '此入口未在当前 macOS 构建中启用。';
      return;
    }
    if (PlPlayerController.instanceExists()) {
      _error = '播放器已有实例。本地诊断要求应用启动后独占播放器；请重启诊断构建后再试。';
      return;
    }

    final args = Get.arguments as Map;
    final heroTag = args['heroTag'] as String;
    _videoDetailController = Get.put(VideoDetailController(), tag: heroTag);
    _introController = Get.put(
      LocalDiagnosticIntroController(diagnosticHeroTag: heroTag),
      tag: heroTag,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPlayback());
  }

  Future<void> _startPlayback() async {
    final detail = _videoDetailController;
    if (!mounted || detail == null) return;
    try {
      final result = await initializeAndStartLocalDiagnosticPlayback(
        initialize: detail.playerInit,
        markPlayerReady: () {
          if (mounted) setState(() => _playerReady = true);
        },
        waitForPlayerViewMount: _waitForPlayerViewMount,
        startPlayback: () async {
          if (!mounted || _closing) return false;
          final playerController = detail.plPlayerController;
          final source = playerController.dataSource;
          final player = playerController.videoPlayerController;
          if (source is! DirectFileSource || player is! NativePlayer) {
            setState(() => _error = '当前本地诊断源或播放器已失效。');
            return false;
          }
          bool isCurrent() =>
              mounted &&
              isCurrentDiagnosticSource(
                source: source,
                player: player,
                currentSource: playerController.dataSource,
                currentPlayer: playerController.videoPlayerController,
                closing: _closing,
              );
          _bindVideoParams(detail);
          final started = await startLocalDiagnosticPlayback(
            isCurrent: isCurrent,
            isPlayerViewMounted: () => _playerViewKey.currentContext != null,
            play: playerController.play,
            refreshTrackMetadata: _refreshTrackMetadata,
          );
          if (!started && mounted && !_closing) {
            setState(() => _error = '本地视频源在启动期间已更换，未发布旧源诊断信息。');
          }
          return started;
        },
      );
      if (result == LocalDiagnosticStartupResult.playerViewNotMounted) {
        if (mounted && !_closing) {
          setState(() => _error = '播放器视图未能挂载，未启动本地视频播放。');
        }
      }
    } catch (_) {
      if (mounted) setState(() => _trackSummary = '播放器未能打开所选文件');
    }
  }

  Future<bool> _waitForPlayerViewMount() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!mounted || !_playerReady) return false;
      if (_playerViewKey.currentContext != null) return true;
      final nextFrame = Completer<void>();
      WidgetsBinding.instance.scheduleFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!nextFrame.isCompleted) nextFrame.complete();
        });
      });
      WidgetsBinding.instance.ensureVisualUpdate();
      await nextFrame.future;
    }
    return mounted && _playerViewKey.currentContext != null;
  }

  void _bindVideoParams(VideoDetailController detail) {
    final player = detail.plPlayerController.videoPlayerController;
    if (player is! NativePlayer) return;
    final source = detail.plPlayerController.dataSource;
    if (source is! DirectFileSource) return;
    bool isCurrent() =>
        mounted &&
        isCurrentDiagnosticSource(
          source: source,
          player: player,
          currentSource: detail.plPlayerController.dataSource,
          currentPlayer: detail.plPlayerController.videoPlayerController,
          closing: _closing,
        );

    void applyVideoParams(VideoParams params) {
      if (!isCurrent()) return;
      final width = params.dw ?? params.w;
      final height = params.dh ?? params.h;
      if (width is! int || height is! int || width <= 0 || height <= 0) return;
      detail
        ..firstVideo.width = width
        ..firstVideo.height = height
        ..plPlayerController.width = width
        ..plPlayerController.height = height;
      setState(() => _videoDimensions = '$width×$height');
    }

    applyVideoParams(player.state.videoParams);
    _videoParamsSubscription = player.stream.videoParams.listen(
      applyVideoParams,
    );
  }

  @override
  void dispose() {
    _videoParamsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _refreshTrackMetadata() async {
    final detail = _videoDetailController;
    final player = detail?.plPlayerController.videoPlayerController;
    if (detail == null || player is! NativePlayer) {
      if (mounted) setState(() => _trackSummary = '视频轨道参数未知');
      return;
    }
    final source = detail.plPlayerController.dataSource;
    if (source is! DirectFileSource) {
      if (mounted) setState(() => _trackSummary = '当前播放源不是本地诊断文件');
      return;
    }
    bool isCurrent() =>
        mounted &&
        isCurrentDiagnosticSource(
          source: source,
          player: player,
          currentSource: detail.plPlayerController.dataSource,
          currentPlayer: detail.plPlayerController.videoPlayerController,
          closing: _closing,
        );

    final track = await readSelectedVideoTrack(
      readProperty: player.getProperty,
      isCurrent: isCurrent,
    );
    if (!isCurrent()) return;
    setState(() {
      _trackSummary = track == null
          ? '所选视频轨道的 Dolby Vision profile/level 未知'
          : '轨道 ${track.id ?? '未知'} · ${track.codec ?? '编码未知'} · '
                'DV profile ${track.dolbyVisionProfile ?? '未知'} · '
                'level ${track.dolbyVisionLevel ?? '未知'}';
    });
  }

  Future<void> _requestExit() async {
    if (_closing) return;
    _closing = true;
    final detail = _videoDetailController;
    try {
      if (detail != null) {
        final playerController = detail.plPlayerController;
        await _videoParamsSubscription?.cancel();
        _videoParamsSubscription = null;
        // These are the only production waits that expose whether the shared
        // controller has completed native output teardown.
        if (!_disposeRequested) {
          // ignore: invalid_use_of_visible_for_testing_member
          playerController.dispose();
          _disposeRequested = true;
        }
        // ignore: invalid_use_of_visible_for_testing_member
        final teardownDrain = playerController.teardownDrain;
        // ignore: invalid_use_of_visible_for_testing_member
        await teardownDrain;
        // ignore: invalid_use_of_visible_for_testing_member
        if (playerController.hasBlockedTeardowns) {
          throw StateError('Native output teardown is blocked');
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '播放器输出释放未能确认；为避免普通页面接管共享播放器，当前停留在诊断页。';
          _closing = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Get.back<void>();
    });
  }

  @override
  Widget build(BuildContext context) {
    final detail = _videoDetailController;
    final intro = _introController;
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            Get.arguments is Map
                ? (Get.arguments['localVideoName'] as String? ?? '本地视频诊断')
                : '本地视频诊断',
          ),
          leading: IconButton(
            onPressed: _closing ? null : _requestExit,
            icon: const Icon(Icons.arrow_back),
          ),
          actions: [
            IconButton(
              tooltip: '重新读取视频轨道信息',
              onPressed: detail == null || _closing
                  ? null
                  : _refreshTrackMetadata,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: detail == null || intro == null || !_playerReady
            ? Center(child: Text(_error ?? '播放器未启动'))
            : LayoutBuilder(
                builder: (context, constraints) {
                  final maxHeight = constraints.maxHeight;
                  detail
                    ..minVideoHeight = maxHeight
                    ..maxVideoHeight = maxHeight
                    ..videoHeight = maxHeight;
                  return Column(
                    children: [
                      Expanded(
                        child: PLVideoPlayer(
                          key: _playerViewKey,
                          maxWidth: constraints.maxWidth,
                          maxHeight: maxHeight,
                          plPlayerController: detail.plPlayerController,
                          videoDetailController: detail,
                          introController: intro,
                          headerControl: _LocalDiagnosticHeader(
                            key: detail.headerCtrKey,
                            playerController: detail.plPlayerController,
                            videoDetailController: detail,
                          ),
                          bottomControl: Obx(
                            () => BottomControl(
                              maxWidth: constraints.maxWidth,
                              isFullScreen:
                                  detail.plPlayerController.isFullScreen.value,
                              controller: detail.plPlayerController,
                              videoDetailController: detail,
                              buildBottomControl: () => Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PlayOrPauseButton(
                                    plPlayerController:
                                        detail.plPlayerController,
                                  ),
                                  const SizedBox(width: 10),
                                  Obx(
                                    () => Text(
                                      '${detail.plPlayerController.position.value}s / '
                                      '${detail.plPlayerController.duration.value}s',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            const Text('本地诊断 · 源类型与色彩参数初始未知'),
                            Text('视频尺寸：$_videoDimensions'),
                            Text(_trackSummary),
                            if (_error case final error?)
                              Text(
                                error,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _LocalDiagnosticHeader extends StatefulWidget {
  const _LocalDiagnosticHeader({
    required this.playerController,
    required this.videoDetailController,
    super.key,
  });

  final PlPlayerController playerController;
  final VideoDetailController videoDetailController;

  @override
  State<_LocalDiagnosticHeader> createState() => _LocalDiagnosticHeaderState();
}

class _LocalDiagnosticHeaderState extends State<_LocalDiagnosticHeader>
    with TimeBatteryMixin {
  @override
  PlPlayerController get plPlayerController => widget.playerController;

  @override
  bool get isPortrait => widget.videoDetailController.isPortrait;

  @override
  bool get isFullScreen => plPlayerController.isFullScreen.value;

  @override
  bool get horizontalScreen => widget.videoDetailController.horizontalScreen;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class LocalDiagnosticIntroController extends CommonIntroController {
  LocalDiagnosticIntroController({required this.diagnosticHeroTag});

  final String diagnosticHeroTag;

  @override
  // ignore: must_call_super
  void onInit() {
    // Do not call CommonIntroController.onInit: it requires Bilibili bvid/cid,
    // starts online-total requests, and starts its timer. Get.put has already
    // invoked this GetX lifecycle callback; the diagnostic intro only needs
    // in-memory values consumed by the shared player widget.
    heroTag = diagnosticHeroTag;
    hasLater.value = false;
    total.value = '1';
    videoTags.value = null;
    videoDetail.value.title = '本地视频诊断';
  }

  @override
  void onReady() {
    // CommonIntroController has no onReady behavior; preserve GetX's required
    // lifecycle while keeping this diagnostic path network-free.
    super.onReady();
  }

  @override
  void onClose() {
    // Preserve GetX and TripleMixin cleanup (timer cancellation and ticker
    // disposal) without running any Bilibili-source behavior.
    super.onClose();
  }

  @override
  void queryVideoIntro() {}

  @override
  int get copyright => 0;

  @override
  void actionLikeVideo() {}

  @override
  void actionShareVideo(context) {}

  @override
  void actionTriple() {}

  @override
  Future<void> actionFavVideo({bool isQuick = false}) async {}

  @override
  (Object, int) get getFavRidType => (0, 0);

  @override
  StatDetail? getStat() => null;

  @override
  bool get isShowOnlineTotal => false;

  @override
  bool prevPlay() => false;

  @override
  bool nextPlay() => false;
}
