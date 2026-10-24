// HDR 档位菜单准入（面板能力唯一判定 + 用户 HDR 偏好）策略切片测试。
//
// 夹具沿用 dovi_facts_routing_integration_test.dart：真实 page、Android
// session override、MethodChannel 分路 mock、fake sniff、显式 cid 初始化。
// 路由 facts 全部走生产链（DashRouteSelection.query + fake sniff 注入），
// 面板标志经 owner 的 L 状态摆放（宿主打不到 Android probe 分支）。
// fullStack 夹具补齐 fake Player/Output/Session，用于断言「保留当前播放」
// 与「画质已变为」在真实开源之后。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' hide HdrCapabilities;
import 'package:media_kit_video/media_kit_video.dart'
    as routing
    show HdrCapabilities;
// Test-only ports into the real Session coordinator and decode review.
// ignore: implementation_imports
import 'package:media_kit_video/src/hdr/hdr_decoder_review.dart';
// ignore: implementation_imports
import 'package:media_kit_video/src/hdr/hdr_open_coordinator.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/messages.g.dart';

import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/common/video/video_type.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/pages/video/controller.dart';
import 'package:piliplus/pages/video/video_quality_eligibility.dart';
import 'package:piliplus/plugin/pl_player/models/data_status.dart';
import 'package:piliplus/plugin/pl_player/controller.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart' as app_hdr;
import 'package:piliplus/plugin/pl_player/models/data_source.dart';
import 'package:piliplus/plugin/pl_player/models/player_lifecycle_ports.dart';
import 'package:piliplus/utils/path_utils.dart' as app_paths;
import 'package:piliplus/utils/storage.dart';
import 'package:piliplus/utils/storage_key.dart';

VideoItem dv126({
  String baseUrl = 'https://cdn.example/dv1-1-30126.m4s',
  String codec = 'hvc1.2.4.L150.90',
  int bandWidth = 9612522,
}) => VideoItem(
  id: 126,
  quality: VideoQuality.fromCode(126),
  codecs: codec,
  baseUrl: baseUrl,
  segmentBase: {'initialization': '0-816'},
  width: 3840,
  height: 2160,
  frameRate: '29.970',
  bandWidth: bandWidth,
);

VideoItem hdr125({
  String baseUrl = 'https://cdn.example/hdr1-1-30125.m4s',
}) => VideoItem(
  id: 125,
  quality: VideoQuality.fromCode(125),
  codecs: 'hvc1.2.4.L153.90',
  baseUrl: baseUrl,
  segmentBase: {'initialization': '0-816'},
  width: 3840,
  height: 2160,
  frameRate: '29.970',
  bandWidth: 8500000,
);

VideoItem vivid129({
  String baseUrl = 'https://cdn.example/vivid1-1-30129.m4s',
}) => VideoItem(
  id: 129,
  quality: VideoQuality.fromCode(129),
  codecs: 'hvc1.2.4.L150.90',
  baseUrl: baseUrl,
  segmentBase: {'initialization': '0-816'},
  width: 3840,
  height: 2160,
  frameRate: '29.970',
  bandWidth: 9000000,
);

VideoItem sdrTrack(
  int id,
  VideoQuality quality, {
  String baseUrl = 'https://cdn.example/sdr1-1-30112.m4s',
  int bandWidth = 4021000,
}) => VideoItem(
  id: id,
  quality: quality,
  codecs: 'avc1.640028',
  baseUrl: baseUrl,
  width: 1920,
  height: 1080,
  frameRate: '29.970',
  bandWidth: bandWidth,
);

VideoItem sdr1080() => sdrTrack(80, VideoQuality.high1080);

VideoItem sdr720() => sdrTrack(
  64,
  VideoQuality.high720,
  baseUrl: 'https://cdn.example/sdr1-1-30064.m4s',
  bandWidth: 2000000,
);

/// 127（8K、非 HDR 编号）轨：macOS 8K 硬解门的候选形态。
VideoItem eightKTrack(
  String codec, {
  String baseUrl = 'https://cdn.example/8k1-1-30127.m4s',
}) => VideoItem(
  id: 127,
  quality: VideoQuality.super8k,
  codecs: codec,
  baseUrl: baseUrl,
  segmentBase: {'initialization': '0-816'},
  width: 7680,
  height: 4320,
  frameRate: '29.970',
  bandWidth: 60000000,
);

PlayUrlModel playUrlOf(List<VideoItem> tracks) =>
    PlayUrlModel(dash: Dash(video: tracks));

const routeUnsupportedMessage = '当前解码或 HDR 输出路径不支持该档位';
const hdrOffMessage = '已关闭 HDR 输出';

/// 选源批量查询（sources 非空）与面板查询（sources 为空）共走一条
/// MethodChannel；宿主打不到 Android 面板分支，面板查询分支仅为完整。
class _CapsBackend {
  _CapsBackend();

  List<int> displayHdrTypes = const [1, 2];
  String codecSupport = 'supported';
  bool failSourceQuery = false;
  bool includeAvcDecoder = true;

  /// 8K 门用例：补一条 AV1 硬解 decoder，使 127 的 AV1 轨在 Android 路由面
  /// 也被 `_routeAllows` 准入——被测对象只剩 App 侧 8K 硬解资格门本身。
  bool includeAv1Decoder = false;
  int sourceQueryCalls = 0;

  /// T14：武装后把下一条选源查询挂起，供测试在挂起期间发布新 revision。
  bool armGateOnNextQuery = false;
  final heldQueryStarted = Completer<void>();
  final heldQueryGate = Completer<void>();

  /// B2：武装后把下一条面板查询（sources 为空——`_initPlayer` 的目标能力
  /// 查询）挂起。该查询是首开路径 publish 之前的第一个真实 await，
  /// 在此挂起即构造「未发布首开」边界。
  bool armGateOnNextPanelQuery = false;
  final heldPanelQueryStarted = Completer<void>();
  final heldPanelQueryGate = Completer<void>();

  Map<String, Object?> _body(List<Map> sources) => {
    'schema': 1,
    'platform': 'android',
    'display': {
      'status': 'resolved',
      'platform': 'android',
      'displayId': 0,
      'modeId': 0,
      'revision': '1:0',
      'hdrTypes': displayHdrTypes,
    },
    'hdr': {
      'sdkInt': 34,
      'p5Pipeline': true,
      'dataSpaceBridgeLoaded': true,
      'nativeDvBridgeApi': 1,
      'dolbyVisionDecoders': [
        {
          'name': 'vendor.dv',
          'mimeType': 'video/dolby-vision',
          'hardwareAcceleration': true,
          'profiles': [32, 256],
        },
      ],
      'hevcDecoders': [
        {
          'name': 'vendor.hevc',
          'mimeType': 'video/hevc',
          'hardwareAcceleration': true,
          'profiles': [1, 2],
        },
      ],
    },
    'sources': [
      for (final Map spec in sources)
        {
          'key': spec['key'],
          'censusComplete': true,
          'reason': 'test',
          'decoders': [
            if (includeAvcDecoder)
              {
                'name': 'vendor.avc',
                'mime': 'video/avc',
                'kind': 'hardware',
                'support': 'supported',
                'reason': 'test',
                'path': 'codec',
              },
            if (includeAv1Decoder)
              {
                'name': 'vendor.av1',
                'mime': 'video/av1',
                'kind': 'hardware',
                'support': 'supported',
                'reason': 'test',
                'path': 'codec',
              },
            {
              'name': 'vendor.hevc',
              'mime': 'video/hevc',
              'kind': 'hardware',
              'support': codecSupport,
              'reason': 'test',
              'path': 'codec',
            },
            {
              'name': 'vendor.dv',
              'mime': 'video/dolby-vision',
              'kind': 'hardware',
              'support': 'supported',
              'reason': 'test',
              'path': 'nativeDv',
            },
          ],
        },
    ],
  };

  Future<Object?> handle(MethodCall call) async {
    if (call.method != 'VideoRouteCapabilities.Get') return null;
    final args = call.arguments as Map;
    final sources = (args['sources'] as List).cast<Map>();
    if (sources.isEmpty) {
      if (armGateOnNextPanelQuery) {
        armGateOnNextPanelQuery = false;
        if (!heldPanelQueryStarted.isCompleted) {
          heldPanelQueryStarted.complete();
        }
        return heldPanelQueryGate.future.then((_) => _body(const []));
      }
      return _body(const []);
    }
    sourceQueryCalls++;
    if (failSourceQuery) {
      throw PlatformException(code: 'injected-source-query-failure');
    }
    if (armGateOnNextQuery) {
      armGateOnNextQuery = false;
      if (!heldQueryStarted.isCompleted) heldQueryStarted.complete();
      return heldQueryGate.future.then((_) => _body(sources));
    }
    return _body(sources);
  }
}

/// fullStack 夹具的会话后端：记录 plan/open，可门控 open 以证明
/// `changeVideoQuality` 在开源完成前不返回 true。
class _OpenBackend implements HdrOpenBackend<HdrOpenPlan> {
  _OpenBackend(this.events);

  final List<String> events;
  late Player player;
  final plans = <HdrOpenPlan>[];
  final openGate = Completer<void>();
  final openStarted = Completer<void>();
  bool gateOpen = false;
  String hwdec = '';

  @override
  Future<void> validate(HdrOpenPlan plan) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> resetOwnedConfiguration() async {}
  @override
  Future<void> prepareOutput(HdrOpenPlan plan) async {}
  @override
  Future<void> configure(HdrOpenPlan plan) async {
    plans.add(plan);
    hwdec = plan.route.hwdec;
    events.add('configure:${plan.media.uri}');
  }

  @override
  Future<void> waitForOutput(HdrOpenPlan plan) async {}
  @override
  Future<void> open(
    HdrOpenPlan plan, {
    Duration? start,
    required bool play,
  }) async {
    if (!openStarted.isCompleted) openStarted.complete();
    if (gateOpen) await openGate.future;
    await player.open(plan.media.copyWith(start: start), play: play);
    events.add('open:${plan.media.uri}');
  }

  @override
  Future<HdrReviewFacts> reviewFacts(HdrOpenPlan plan) async => HdrReviewFacts(
    path: plan.media.uri,
    codec: 'h264',
    hwdecCurrent: hwdec,
    videoParams: const VideoParams(primaries: 'bt.709', gamma: 'bt.1886'),
    decoderObservation: HdrDecoderObservation(
      playlistEntryId: 1,
      fileLoadedEpoch: plans.length,
      decoder: hwdec == 'no' ? 'h264' : 'h264_mediacodec',
      decoderDescription: 'test',
      hwdec: hwdec,
      pixelFormat: hwdec == 'mediacodec' ? 'mediacodec' : 'yuv420p',
      hwPixelFormat: hwdec == 'mediacodec' ? 'mediacodec' : '',
    ),
  );

  @override
  HdrBackendObservation observe() => HdrBackendObservation(hwdecCurrent: hwdec);

  Future<void> disposeOutput() async {}
  Future<void> disposeBackend() async {}
}

class _FakePlayer implements Player {
  _FakePlayer() {
    stream = PlayerStream(
      _empty<Playlist>(),
      playing.stream,
      _empty<bool>(),
      _empty<Duration>(),
      _empty<Duration>(),
      _empty<double>(),
      _empty<double>(),
      _empty<double>(),
      _empty<bool>(),
      _empty<double>(),
      buffer.stream,
      _empty<PlaylistMode>(),
      _empty<bool>(),
      _empty<AudioParams>(),
      videoParams.stream,
      _empty<double?>(),
      _empty<double?>(),
      _empty<AudioDevice>(),
      _empty<List<AudioDevice>>(),
      _empty<Track>(),
      _empty<Tracks>(),
      _empty<int?>(),
      _empty<int?>(),
      _empty<List<String>>(),
      _empty<PlayerLog>(),
      _empty<String>(),
    );
  }

  final videoParams = StreamController<VideoParams>.broadcast(sync: true);
  final playing = StreamController<bool>.broadcast(sync: true);
  final buffer = StreamController<Duration>.broadcast(sync: true);
  @override
  late final PlayerStream stream;
  @override
  PlayerState state = const PlayerState(
    duration: Duration(minutes: 2),
    rate: 1,
  );
  @override
  List<Media> current = [];
  final opened = <Playable>[];
  int pauseCalls = 0;
  @override
  bool disposed = false;

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) {
    opened.add(playable);
    if (playable is Media) current = [playable];
    return Future<void>.value();
  }

  @override
  Future<void> pause({bool synchronized = true}) async {
    pauseCalls++;
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool synchronized = true,
  }) async {}

  @override
  Future<void> setRate(double rate, {bool synchronized = true}) async {
    state = state.copyWith(rate: rate);
  }

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {}

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => '';

  @override
  Future<void> dispose({bool synchronized = true}) async {
    disposed = true;
  }

  Future<void> closeStreams() async {
    await videoParams.close();
    await playing.close();
    await buffer.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVideoController implements VideoController {
  _FakeVideoController(this.player, this.configuration) {
    final platformController = _FakePlatformVideoController(
      player,
      configuration,
    );
    platform.complete(platformController);
    notifier.value = platformController;
  }

  @override
  final Player player;

  final VideoControllerConfiguration configuration;

  @override
  final Completer<PlatformVideoController> platform = Completer();

  @override
  final ValueNotifier<PlatformVideoController?> notifier = ValueNotifier(null);

  @override
  final ValueNotifier<int?> id = ValueNotifier(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlatformVideoController implements PlatformVideoController {
  _FakePlatformVideoController(this.player, this.configuration);

  @override
  final Player player;

  @override
  final VideoControllerConfiguration configuration;

  @override
  final ValueNotifier<bool> nativeSurfaceActiveNotifier = ValueNotifier(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Stream<T> _empty<T>() => Stream<T>.empty();

class _Harness {
  _Harness({this.fullStack = false, this.androidSession = true});

  final bool fullStack;

  /// false 模拟非 Android 路由面（usesAndroidRouting=false）。
  final bool androidSession;
  final caps = _CapsBackend();
  late final openBackend = _OpenBackend(events);
  final players = <_FakePlayer>[];
  final events = <String>[];

  late final ports = PlayerLifecyclePorts(
    androidSessionOverride: androidSession,
    createHdrSession: fullStack
        ? (player, target) {
            openBackend.player = player;
            return HdrVideoSession.forTesting(
              player: player,
              isAndroid: true,
              target: target,
              backend: openBackend,
              disposeOutputForTesting: openBackend.disposeOutput,
              disposeBackendForTesting: openBackend.disposeBackend,
              capabilitiesProvider: () async => const routing.HdrCapabilities(
                sdkInt: 34,
                displayHdrTypes: {1, 2, 3, 4},
                hevcDecoders: [],
                dolbyVisionDecoders: [],
                p5PipelineAvailable: true,
                dataSpaceBridgeLoaded: true,
                dataSpaceExt: null,
              ),
            );
          }
        : null,
    createPlayer: fullStack
        ? (configuration) async {
            final player = _FakePlayer();
            players.add(player);
            return player;
          }
        : (_) async => throw StateError('routing must not create Player'),
    probeHdr: () async =>
        const app_hdr.HdrCapabilities(unsupportedReason: 'unused'),
    createOutput: fullStack
        ? (player, configuration) async =>
              _FakeVideoController(player, configuration)
        : (_, _) async => throw StateError('routing must not create output'),
    displayChanges: () => const Stream<void>.empty(),
    disposeOutput: (_) async {},
    disposePlayer: (player) async {
      (player as _FakePlayer).disposed = true;
    },
  );

  late final owner = PlPlayerController.getInstance(lifecyclePorts: ports);

  // 页面字段初始化会调用无 ports 的 getInstance()：先取 owner 固定端口，
  // 否则共享实例会先以无端口形态被创建。
  late final page = () {
    assert(identical(owner, PlPlayerController.instance));
    return VideoDetailController()
      ..cid = RxInt(452419749)
      ..isFileSource = false
      ..videoType = VideoType.ugc;
  }();

  void installCaps(TestDefaultBinaryMessenger messenger) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.alexmercerind/media_kit_video'),
          caps.handle,
        );
  }

  /// 通用摆放：平台 seam 置 Android、绑定 HDR 回调、toast sink 记录到
  /// 事件日志（与 open 事件共享，用于断言时点）。
  void setupPage({
    required VideoItem firstVideo,
    required bool displayHdr,
    bool routingPlatformIsAndroid = true,
  }) {
    page
      ..aid = 12345
      ..bvid = 'BV1test'
      ..firstVideo = firstVideo
      ..isVertical = RxBool(false)
      ..vttSubtitlesIndex.value = 0
      ..autoPlay = true;
    page.pageToastSinkForTesting = (message) {
      events.add('toast:$message');
    };
    page
      ..routingPlatformIsAndroidForTesting = routingPlatformIsAndroid
      ..bindHdrDisplayCallbackForTesting();
    // 宿主打不到 L 的 Android probe 分支：面板标志按生产语义由 L 发布，
    // 这里直接摆放 L 的公开状态作为夹具输入。
    owner.hdrDisplaySupportsHdr.value = displayHdr;
  }

  /// HDR 关闭偏好：必须在 probe 之前 await，否则 Box 写入与 resolve() 竞态。
  Future<void> setupHdrOff() async {
    await GStorage.setting.put(SettingBoxKey.hdrMode, 'off');
    addTearDown(() => GStorage.setting.put(SettingBoxKey.hdrMode, 'auto'));
  }

  Future<void> close({bool skipOwnerDispose = false}) async {
    const MethodChannel('com.alexmercerind/media_kit_video');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.alexmercerind/media_kit_video'),
          null,
        );
    page.releaseRoutingForTesting();
    expect(owner.onRouteOptionsInvalidated, isNull);
    expect(owner.onRouteOptionsChanged, isNull);
    expect(owner.onHdrDisplayChanged, isNull);
    if (!skipOwnerDispose) {
      owner.dispose();
    }
    await owner.teardownDrain;
    for (final player in players) {
      await player.closeStreams();
    }
    expect(PlPlayerController.instance, isNull);
  }
}

Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within ${timeout.inMilliseconds}ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('hdr-tier-menu-');
    app_paths.appSupportDirPath = directory.path;
    app_paths.tmpDirPath = directory.path;
    await GStorage.init();
    messenger
      ..setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
          WakelockPlusApi.pigeonChannelCodec,
        ),
        (message) async => <Object?>[null],
      )
      ..setMockMethodCallHandler(const MethodChannel('window_manager'), (
        call,
      ) async {
        if (call.method == 'isFullScreen') return false;
        return null;
      });
  });

  tearDownAll(() async {
    await GStorage.close();
    await directory.delete(recursive: true);
  });

  /// R2/B3 之后 updatePlayer/playerInit 都不再能（重）开未准入 rendition；
  /// D 路径场景的既定前提是「126 已在实际播放」（策略生效前的存量状态），
  /// 因此直接在 owner 层开一次源，再叠加页面状态后触发面板/偏好事件。
  Future<void> openLegacyPlaying126(
    _Harness h,
    VideoItem item,
  ) async {
    await h.owner.setDataSource(
      NetworkSource(videoSource: item.baseUrl!, audioSource: null),
      autoplay: false,
      initialVideoQuality: 126,
      initialVideoCodec: item.codecs,
      width: item.width,
      height: item.height,
    );
    h.owner.cacheVideoQa = 126;
    h.page
      ..firstVideo = item
      ..videoUrl = item.baseUrl!
      ..currentVideoQa.value = VideoQuality.fromCode(126);
  }

  // T1：HDR 面板 + 126 裸 hvc1 + 无 facts → 菜单纯展示白。
  test(
    'T1: HDR panel, bare hvc1 126 without facts renders the tier enabled',
    () async {
      final h = _Harness();
      final item = dv126();
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080(), item]), 1),
          isTrue,
        );
        // 路由 facts 未到（unresolved）：开源准入仍拒绝，但菜单不再灰。
        expect(h.page.routingSelectionForTesting!.allows(item), isFalse);
        final eligibility = h.page.qualityEligibility(126);
        expect(eligibility.enabled, isTrue, reason: eligibility.message);
        expect(h.page.qualityEligibility(80).enabled, isTrue);
      } finally {
        await h.close();
      }
    },
  );

  // T2：T1 之下点击 126 → 开源前守卫拒绝；处于播放中的 Player/Session
  // 零 pause/open/dispose（V2 复核要求）。
  test(
    'T2: clicking the unresolved 126 tier refuses without touching the player',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126();
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080(), item]), 1),
          isTrue,
        );
        // 建立播放中的 80（正常准入路径），并把 fake Player 置为 playing。
        h.owner.cacheVideoQa = 80;
        h.page.currentVideoQa.value = VideoQuality.fromCode(80);
        await h.page.updatePlayer();
        final player = h.players.single;
        player.state = player.state.copyWith(playing: true);
        final session = h.owner.hdrVideoSession.value;
        expect(session, isNotNull);
        final cacheBefore = h.owner.cacheVideoQa;
        final accepted = await h.page.changeVideoQuality(126);
        expect(accepted, isFalse);
        expect(
          h.events.where((event) => event.startsWith('toast:')),
          [const PrefixMatcher('toast:$routeUnsupportedMessage')],
        );
        expect(player.pauseCalls, 0, reason: '保留当前播放：零 pause');
        expect(player.opened, hasLength(1), reason: '零 open');
        expect(player.disposed, isFalse, reason: '零 dispose');
        expect(h.players, hasLength(1), reason: '不得创建新 Player');
        expect(h.owner.hdrVideoSession.value, same(session));
        expect(h.owner.dataStatus.value, DataStatus.loaded);
        expect(h.page.currentVideoQa.value?.code, 80);
        expect(h.owner.cacheVideoQa, cacheBefore);
        expect(h.page.routingSelectionForTesting!.allows(item), isFalse);
      } finally {
        await h.close();
      }
    },
  );

  // T3a：SDR 面板菜单 → displayHdrUnsupported。
  test('T3a: SDR panel keeps HDR tiers gray with the display reason', () async {
    final h = _Harness();
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: false);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    try {
      expect(
        await h.page.probeRoutingForTesting(
          playUrlOf([item, sdr1080()]),
          1,
        ),
        isTrue,
      );
      final eligibility = h.page.qualityEligibility(126);
      expect(
        eligibility.reason,
        VideoQualityIneligibility.displayHdrUnsupported,
      );
      expect(eligibility.message, '当前显示器不支持 HDR 输出');
      expect(h.page.qualityEligibility(80).enabled, isTrue);
    } finally {
      await h.close();
    }
  });

  // T3b：SDR 面板真实冷启动、缓存 126 → 实选 admitted 轨中质量值最高者
  //（不依赖服务器顺序）+ 选源成功后恰一次降档提示。
  test('T3b: cold start with cached 126 on an SDR panel opens the highest SDR and toasts', () async {
    for (final orders in [
      [126, 64, 80],
      [80, 126, 64],
      [64, 80, 126],
    ]) {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: false);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        final tracks = [
          for (final id in orders)
            switch (id) {
              126 => item,
              80 => sdr1080(),
              _ => sdr720(),
            },
        ];
        expect(
          await h.page.probeRoutingForTesting(playUrlOf(tracks), 1),
          isTrue,
        );
        h.owner.cacheVideoQa = 126;
        await h.page.selectInitialSourceForTesting();
        expect(h.page.currentVideoQa.value?.code, 80, reason: '$orders');
        expect(h.page.firstVideo.id, 80);
        expect(h.openBackend.plans, isNotEmpty);
        expect(
          h.events,
          contains('toast:当前设备无法以 HDR 播放该档位，已切换到：1080P 高清'),
        );
        expect(
          h.events.where((event) => event.startsWith('toast:')).length,
          1,
          reason: '冷启动降档只提示一次',
        );
      } finally {
        await h.close();
      }
    }
  });

  // T3b(b)：缓存档不存在于本片 DASH，或存在但无合格 codec（无法构成有效
  // rendition）→ 落最高 SDR 但**不**提示降档。
  test(
    'T3b(b): absent or codec-less cached HDR tier downgrades silently',
    () async {
      for (final (label, tracks) in [
        ('absent', <VideoItem>[sdr1080(), sdr720()]),
        (
          'codec-less',
          <VideoItem>[
            VideoItem(
              id: 126,
              quality: VideoQuality.fromCode(126),
              codecs: null,
              baseUrl: 'https://cdn.example/broken126.m4s',
              width: 3840,
              height: 2160,
            ),
            sdr1080(),
          ],
        ),
      ]) {
        final h = _Harness(fullStack: true)
          ..setupPage(firstVideo: sdr1080(), displayHdr: false)
          ..installCaps(messenger);
        h.page.setDoviSniffForTesting((item) async => null);
        h.owner.onVideoViewMounted();
        try {
          expect(
            await h.page.probeRoutingForTesting(playUrlOf(tracks), 1),
            isTrue,
          );
          h.owner.cacheVideoQa = 126;
          await h.page.selectInitialSourceForTesting();
          expect(h.page.currentVideoQa.value?.code, 80, reason: label);
          expect(
            h.events.where((event) => event.startsWith('toast:')),
            isEmpty,
            reason: '$label：档位不可构成有效 rendition，不提示「已切换」',
          );
        } finally {
          await h.close();
        }
      }
    },
  );

  // T3c：首次 false 回调早于 data 赋值 → 不抛、静默返回。
  test(
    'T3c: first false panel callback before any DASH response does not throw',
    () async {
      final h = _Harness()
        ..setupPage(firstVideo: dv126(), displayHdr: true)
        ..installCaps(messenger);
      try {
        expect(() => h.owner.onHdrDisplayChanged!(false), returnsNormally);
        expect(h.events, isEmpty);
        expect(h.players, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  // T4a：HDR 面板已确认 + source query 瞬时失败 → 面板标志保持 true、126 白。
  test(
    'T4a: a failed source query no longer overwrites the panel flag',
    () async {
      final h = _Harness();
      final item = dv126();
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080(), item]), 1),
          isTrue,
        );
        h.caps.failSourceQuery = true;
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080(), item]), 2),
          isTrue,
        );
        expect(h.owner.hdrDisplaySupportsHdr.value, isTrue);
        expect(h.page.qualityEligibility(126).enabled, isTrue);
      } finally {
        await h.close();
      }
    },
  );

  // T4b：已确认 false + 查询失败 → 不被翻 true。
  test(
    'T4b: a failed source query does not flip a confirmed-false flag up',
    () async {
      final h = _Harness();
      final item = dv126();
      h.setupPage(firstVideo: item, displayHdr: false);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080(), item]), 1),
          isTrue,
        );
        h.caps.failSourceQuery = true;
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080(), item]), 2),
          isTrue,
        );
        expect(h.owner.hdrDisplaySupportsHdr.value, isFalse);
        expect(
          h.page.qualityEligibility(126).reason,
          VideoQualityIneligibility.displayHdrUnsupported,
        );
      } finally {
        await h.close();
      }
    },
  );

  // T5：SDR 面板 + HDR 关闭 + 125 → 灰，原因 hdrModeOff。
  test(
    'T5: SDR panel with HDR off grays 125 for the user-preference reason',
    () async {
      final h = _Harness();
      final item = hdr125();
      h.setupPage(firstVideo: item, displayHdr: false);
      await h.setupHdrOff();
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      try {
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, sdr1080()]),
            1,
          ),
          isTrue,
        );
        final eligibility = h.page.qualityEligibility(125);
        expect(eligibility.reason, VideoQualityIneligibility.hdrModeOff);
        expect(eligibility.message, hdrOffMessage);
        expect(h.page.qualityEligibility(80).enabled, isTrue);
      } finally {
        await h.close();
      }
    },
  );

  // T6a：面板 HDR→false 事件 + 当前 126 → 最终实选 SDR 轨；HDR 关闭同样降档。
  test('T6a: panel HDR->false while playing 126 downgrades to the highest SDR track', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      expect(
        await h.page.probeRoutingForTesting(
          playUrlOf([item, sdr720(), sdr1080()]),
          1,
        ),
        isTrue,
      );
      h.owner.cacheVideoQa = 126;
      h.page.currentVideoQa.value = VideoQuality.fromCode(126);
      await h.page.updatePlayer();
      expect(h.page.firstVideo.id, 126);
      final openedBefore = h.players.last.opened.length;
      // 模拟 L 的发布顺序：先翻标志，再回调 false。
      h.owner.hdrDisplaySupportsHdr.value = false;
      h.owner.onHdrDisplayChanged!(false);
      await waitUntil(
        () => h.events.any(
          (event) => event.startsWith('toast:当前显示器不支持 HDR，已切换到'),
        ),
      );
      expect(h.page.currentVideoQa.value?.code, 80);
      expect(h.page.firstVideo.id, 80);
      expect(h.players.last.opened.length, openedBefore + 1);
      final switchIndex = h.events.indexWhere(
        (event) => event.startsWith('toast:当前显示器不支持 HDR，已切换到'),
      );
      expect(
        h.events[switchIndex - 1].startsWith('open:'),
        isTrue,
        reason: '「已切换到」必须在开源完成之后',
      );
      expect(h.events[switchIndex], 'toast:当前显示器不支持 HDR，已切换到：1080P 高清');
    } finally {
      await h.close();
    }
  });

  test(
    'T6a(b): HDR off with the panel losing HDR still downgrades 126 to SDR',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, sdr1080()]),
            1,
          ),
          isTrue,
        );
        await openLegacyPlaying126(h, item);
        h.owner.hdrDisplaySupportsHdr.value = false;
        h.owner.onHdrDisplayChanged!(false);
        await waitUntil(
          () => h.events.any(
            (event) => event.startsWith('toast:当前显示器不支持 HDR，已切换到'),
          ),
        );
        expect(h.page.currentVideoQa.value?.code, 80);
      } finally {
        await h.close();
      }
    },
  );

  // T6b：面板 HDR→false 且无合格 SDR → 提示、不静默、不崩。
  test('T6b: panel HDR->false without a playable SDR track toasts instead of staying silent', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item]), 1),
        isTrue,
      );
      h.owner.cacheVideoQa = 126;
      h.page.currentVideoQa.value = VideoQuality.fromCode(126);
      await h.page.updatePlayer();
      final openedBefore = h.players.last.opened.length;
      h.owner.hdrDisplaySupportsHdr.value = false;
      h.owner.onHdrDisplayChanged!(false);
      await waitUntil(
        () => h.events.contains('toast:当前显示器不支持 HDR，且没有可播放的 SDR 画质'),
      );
      expect(h.page.currentVideoQa.value?.code, 126);
      expect(h.players.last.opened.length, openedBefore, reason: '空集不重开');
    } finally {
      await h.close();
    }
  });

  // D-8K-a：面板 HDR→false + DASH{126, 127(AV1 路由准入但 8K 硬解
  // pending), 80} → 降级候选必须先过 8K 资格门：开 80、恰一次「已切换到」
  // 且在 open 之后、零 open 127。
  test(
    'D-8K-a: panel HDR->false with a gated 8K candidate downgrades to 80, not 127',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.caps.includeAv1Decoder = true;
      h.owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, eightKTrack('av01.0.17M.08'), sdr1080()]),
            1,
          ),
          isTrue,
        );
        h.owner.cacheVideoQa = 126;
        h.page.currentVideoQa.value = VideoQuality.fromCode(126);
        await h.page.updatePlayer();
        expect(h.page.firstVideo.id, 126);
        final opensBefore = h.events
            .where((event) => event.startsWith('open:'))
            .length;
        h.owner.hdrDisplaySupportsHdr.value = false;
        h.owner.onHdrDisplayChanged!(false);
        await waitUntil(
          () => h.events.any(
            (event) => event.startsWith('toast:当前显示器不支持 HDR，已切换到'),
          ),
        );
        expect(h.page.currentVideoQa.value?.code, 80);
        expect(h.page.firstVideo.id, 80);
        final opens = h.events
            .where((event) => event.startsWith('open:'))
            .toList();
        expect(opens, hasLength(opensBefore + 1), reason: '恰一次降级 open');
        expect(opens.last, contains('sdr1-1-30112'));
        expect(
          opens.where((event) => event.contains('8k1-1-30127')),
          isEmpty,
          reason: '零 open 127',
        );
        final switchToasts = h.events
            .where((event) => event.startsWith('toast:当前显示器不支持 HDR，已切换到'))
            .toList();
        expect(switchToasts, hasLength(1), reason: '恰一次「已切换到」');
        final switchIndex = h.events.indexOf(switchToasts.single);
        expect(
          h.events[switchIndex - 1].startsWith('open:'),
          isTrue,
          reason: '「已切换到」必须在开源完成之后',
        );
        expect(switchToasts.single, 'toast:当前显示器不支持 HDR，已切换到：1080P 高清');
      } finally {
        await h.close();
      }
    },
  );

  // D-8K-b：DASH{126, 127(AV1 硬解 failed)}（无 80）→ 8K 门后无可播 SDR：
  // 不写入虚假的 127 状态（currentVideoQa 仍 126）、零 open、空集 toast、
  // 无「已切换」。
  test(
    'D-8K-b: panel HDR->false with only a gated 8K SDR keeps 126 and toasts the empty set',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      final eightK = eightKTrack('av01.0.17M.08');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.caps.includeAv1Decoder = true;
      h.owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, eightK]),
            1,
          ),
          isTrue,
        );
        h.page.seedDecodeCapabilitiesForTesting([
          VideoDecodeCapability.fromTrack(eightK).copyWith(
            hardwareSupported: false,
            reason: 'test-av1-hardware-unavailable',
          ),
        ]);
        h.owner.cacheVideoQa = 126;
        h.page.currentVideoQa.value = VideoQuality.fromCode(126);
        await h.page.updatePlayer();
        expect(h.page.firstVideo.id, 126);
        final opensBefore = h.events
            .where((event) => event.startsWith('open:'))
            .length;
        h.owner.hdrDisplaySupportsHdr.value = false;
        h.owner.onHdrDisplayChanged!(false);
        await waitUntil(
          () => h.events.contains('toast:当前显示器不支持 HDR，且没有可播放的 SDR 画质'),
        );
        expect(h.page.currentVideoQa.value?.code, 126, reason: '不写虚假 127 状态');
        expect(h.page.firstVideo.id, 126);
        final opens = h.events
            .where((event) => event.startsWith('open:'))
            .toList();
        expect(opens, hasLength(opensBefore), reason: '零 open');
        expect(
          opens.where((event) => event.contains('8k1-1-30127')),
          isEmpty,
          reason: '零 open 127',
        );
        expect(
          h.events.where(
            (event) => event.startsWith('toast:当前显示器不支持 HDR，已切换到'),
          ),
          isEmpty,
          reason: '无「已切换」',
        );
      } finally {
        await h.close();
      }
    },
  );

  // D-8K-c：DASH{126, 127(AV1 failed + HEVC confirmed), 80} → 若降到 127
  // 必须是已确认硬解的 HEVC codec（不得 AV1）。
  test(
    'D-8K-c: panel HDR->false downgrade to 127 selects only the confirmed codec',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      final av1 = eightKTrack('av01.0.17M.08');
      final hevc = eightKTrack(
        'hev1.2.4.L183.B0',
        baseUrl: 'https://cdn.example/8k-hevc-1-1-30127.m4s',
      );
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.caps.includeAv1Decoder = true;
      h.owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, hevc, av1, sdr1080()]),
            1,
          ),
          isTrue,
        );
        h.page.seedDecodeCapabilitiesForTesting([
          VideoDecodeCapability.fromTrack(av1).copyWith(
            hardwareSupported: false,
            reason: 'test-av1-hardware-unavailable',
          ),
          VideoDecodeCapability.fromTrack(hevc).copyWith(
            hardwareSupported: true,
            reason: 'test-hevc-hardware-confirmed',
          ),
        ]);
        h.owner.cacheVideoQa = 126;
        h.page.currentVideoQa.value = VideoQuality.fromCode(126);
        await h.page.updatePlayer();
        expect(h.page.firstVideo.id, 126);
        final opensBefore = h.events
            .where((event) => event.startsWith('open:'))
            .length;
        h.owner.hdrDisplaySupportsHdr.value = false;
        h.owner.onHdrDisplayChanged!(false);
        await waitUntil(
          () => h.events.any(
            (event) => event.startsWith('toast:当前显示器不支持 HDR，已切换到'),
          ),
        );
        expect(h.page.currentVideoQa.value?.code, 127);
        expect(h.page.firstVideo.id, 127);
        expect(h.page.firstVideo.codecs, 'hev1.2.4.L183.B0');
        final opens = h.events
            .where((event) => event.startsWith('open:'))
            .toList();
        expect(opens, hasLength(opensBefore + 1));
        expect(opens.last, contains('8k-hevc-1-1-30127'));
        expect(
          opens.where((event) => event.contains('8k1-1-30127')),
          isEmpty,
          reason: '不得 open 未确认硬解的 AV1',
        );
      } finally {
        await h.close();
      }
    },
  );

  // T7：125/129 参数化——菜单与 126 同语义（播放层不在此保证）。
  test('T7: 125/129 follow the same menu admission as 126', () async {
    for (final (quality, item, displayHdr) in [
      (125, hdr125(), true),
      (129, vivid129(), true),
      (125, hdr125(), false),
      (129, vivid129(), false),
    ]) {
      final h = _Harness();
      try {
        h.setupPage(firstVideo: item, displayHdr: displayHdr);
        h.page.setDoviSniffForTesting((item) async => null);
        h.installCaps(messenger);
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
          isTrue,
        );
        if (displayHdr) {
          expect(h.page.qualityEligibility(quality).enabled, isTrue);
        } else {
          expect(
            h.page.qualityEligibility(quality).reason,
            VideoQualityIneligibility.displayHdrUnsupported,
          );
        }
      } finally {
        await h.close();
      }
    }
  });

  // T8：HDR 面板 + P7 dvh1.07 → 菜单白；点击被规划器拒（非 unresolved 分支）。
  test(
    'T8: P7 dvh1.07 renders white and its click is refused by the planner',
    () async {
      final h = _Harness();
      final p7 = dv126(codec: 'dvh1.07.09');
      h.setupPage(firstVideo: p7, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      // 与 dovi P7 反证一致的 mock：无可用 codec 路解码器，全部路由不可行
      // （是本 mock 的能力裁定，不是 P7 的一般裁定）。
      h.caps
        ..codecSupport = 'unsupported'
        ..includeAvcDecoder = false;
      h.installCaps(messenger);
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([p7, sdr1080()]), 1),
          isTrue,
        );
        expect(h.page.routingSelectionForTesting!.allows(p7), isFalse);
        expect(h.page.qualityEligibility(126).enabled, isTrue, reason: '菜单被动白');
        final accepted = await h.page.changeVideoQuality(126);
        expect(accepted, isFalse);
        expect(h.events, [
          const PrefixMatcher('toast:$routeUnsupportedMessage'),
        ]);
        expect(h.players, isEmpty);
        expect(h.owner.hdrVideoSession.value, isNull);
      } finally {
        await h.close();
      }
    },
  );

  // T9：面板标志语义（页面视角）：true→白、false→灰，查询失败不动标志（T4a/T4b 已证）。
  test('T9: menu admission follows only the published panel flag', () async {
    final h = _Harness();
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    try {
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
        isTrue,
      );
      expect(h.page.qualityEligibility(126).enabled, isTrue);
      // unknown-null / 迟到查询不翻动标志：查询失败后标志原样（见 T4a/T4b）。
      h.owner.hdrDisplaySupportsHdr.value = false;
      expect(
        h.page.qualityEligibility(126).reason,
        VideoQualityIneligibility.displayHdrUnsupported,
      );
      h.owner.hdrDisplaySupportsHdr.value = true;
      expect(h.page.qualityEligibility(126).enabled, isTrue);
    } finally {
      await h.close();
    }
  });

  // T10：被动重复渲染菜单 → 零 capability query / sniff / predict 副作用。
  test(
    'T10: repeated passive menu rendering issues no queries or sniffs',
    () async {
      final h = _Harness();
      final item = dv126();
      var sniffCalls = 0;
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async {
        sniffCalls++;
        return null;
      });
      h.installCaps(messenger);
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080(), item]), 1),
          isTrue,
        );
        final callsAfterProbe = h.caps.sourceQueryCalls;
        final sniffsAfterProbe = sniffCalls;
        for (var i = 0; i < 10; i++) {
          h.page.qualityEligibility(126);
          h.page.qualityEligibility(80);
          h.page.currentDashQualityFormats;
        }
        expect(h.caps.sourceQueryCalls, callsAfterProbe);
        expect(sniffCalls, sniffsAfterProbe);
      } finally {
        await h.close();
      }
    },
  );

  // T11：E1 设置变化重开（HDR 关闭）——完整事务轨迹：页面 rendition 决策
  // 在 session setOptions 之前完成，至多一次 open，且全程无 HDR rendition。
  test('T11: settings change with HDR off downgrades before setOptions with exactly one SDR open', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      expect(
        await h.page.probeRoutingForTesting(
          playUrlOf([item, sdr1080()]),
          1,
        ),
        isTrue,
      );
      h.owner.cacheVideoQa = 126;
      h.page.currentVideoQa.value = VideoQuality.fromCode(126);
      await h.page.updatePlayer();
      expect(h.page.firstVideo.id, 126);
      // 用户把 HDR 模式切到关闭：applyRoutePreferences → invalidate →
      // onRouteOptionsChanged（setOptions 之前的 rendition 决策）。
      final marker = h.events.length;
      await GStorage.setting.put(SettingBoxKey.hdrMode, 'off');
      addTearDown(() => GStorage.setting.put(SettingBoxKey.hdrMode, 'auto'));
      await h.owner.applyRoutePreferences();
      final trace = h.events.sublist(marker);
      final opens = trace.where((event) => event.startsWith('open:')).toList();
      expect(
        opens,
        hasLength(1),
        reason: '至多一次 open：页面直接降档重开，不再有 setOptions 的 tone-map 重开',
      );
      expect(opens.single, contains('sdr1-1-30112'), reason: '实开为 SDR 轨');
      expect(
        trace.join(),
        isNot(contains('dv1-1-30126')),
        reason: '设置动作后的轨迹中不得出现任何 HDR rendition/URL',
      );
      expect(h.page.currentVideoQa.value?.code, 80);
      expect(h.page.firstVideo.id, 80);
      expect(
        h.owner.dataSource.routeOptions?.output.isRequired,
        isTrue,
        reason: '新 open 携带 require(sdr) options',
      );
    } finally {
      await h.close();
    }
  });

  // T11(c)：rendition 仍准入（仅 decode 偏好变化）→ setOptions 原地生效，
  // 页面不重开。
  test('T11(c): an admissible rendition keeps playing via in-place setOptions without a reopen', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      expect(
        await h.page.probeRoutingForTesting(
          playUrlOf([item, sdr1080()]),
          1,
        ),
        isTrue,
      );
      h.owner.cacheVideoQa = 126;
      h.page.currentVideoQa.value = VideoQuality.fromCode(126);
      await h.page.updatePlayer();
      expect(h.page.firstVideo.id, 126);
      final session = h.owner.hdrVideoSession.value!;
      final optionsBefore = session.report.value.options;
      final opensBefore = h.events
          .where((event) => event.startsWith('open:'))
          .length;
      // 仅 decode 偏好写法变化：auto → auto-safe，resolved 内容等价
      // （同为 prefer hardware + preferDirect）、实例不同。
      await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto-safe');
      addTearDown(
        () => GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto'),
      );
      await h.owner.applyRoutePreferences();
      // 库的 setOptions 语义本就是按新 options 重开当前 media： rendition
      // 仍准入时这里应且仅应有这一次 setOptions 驱动的重开，且仍是 126；
      // 页面不得另行降档重开。
      final opens = h.events
          .where((event) => event.startsWith('open:'))
          .toList();
      expect(opens, hasLength(opensBefore + 1));
      expect(
        opens.last,
        contains('dv1-1-30126'),
        reason: 'setOptions 照常执行且不降档',
      );
      expect(h.page.currentVideoQa.value?.code, 126);
      expect(h.page.firstVideo.id, 126);
      expect(
        identical(session.report.value.options, optionsBefore),
        isFalse,
        reason: 'setOptions 已按新 options 实例生效',
      );
    } finally {
      await h.close();
    }
  });

  // T11(b)：E2 输出目标变化重开同样不回 HDR。
  test(
    'T11(b): output target refresh with HDR off does not reselect the HDR tier',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, sdr1080()]),
            1,
          ),
          isTrue,
        );
        await openLegacyPlaying126(h, item);
        await h.page.refreshRoutingTargetForTesting();
        await waitUntil(() => h.page.currentVideoQa.value?.code == 80);
        expect(h.page.firstVideo.id, 80);
      } finally {
        await h.close();
      }
    },
  );

  // E1-8K：设置变化重开（HDR 关闭）+ DASH{126, 127(AV1 路由准入但 8K 硬解
  // pending), 80} → 兜底先过 8K 资格门：落 80、零 open 127、不写入虚假的
  // 127 状态。
  test(
    'E1-8K: settings-change reopen with a gated 8K candidate lands on 80',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.caps.includeAv1Decoder = true;
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, eightKTrack('av01.0.17M.08'), sdr1080()]),
            1,
          ),
          isTrue,
        );
        await openLegacyPlaying126(h, item);
        final marker = h.events.length;
        await h.owner.applyRoutePreferences();
        await waitUntil(() => h.page.currentVideoQa.value?.code == 80);
        expect(h.page.firstVideo.id, 80);
        final trace = h.events.sublist(marker);
        final opens = trace
            .where((event) => event.startsWith('open:'))
            .toList();
        expect(opens, isNotEmpty);
        expect(
          opens.where((event) => event.contains('sdr1-1-30112')),
          isNotEmpty,
          reason: '降级 open 落在 80',
        );
        expect(
          opens.where((event) => event.contains('8k1-1-30127')),
          isEmpty,
          reason: '零 open 127',
        );
      } finally {
        await h.close();
      }
    },
  );

  // E2-8K：输出目标变化重开（HDR 关闭）+ 同组合 → 落 80、零 open 127。
  test(
    'E2-8K: output-target refresh with a gated 8K candidate lands on 80',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.caps.includeAv1Decoder = true;
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, eightKTrack('av01.0.17M.08'), sdr1080()]),
            1,
          ),
          isTrue,
        );
        await openLegacyPlaying126(h, item);
        final marker = h.events.length;
        await h.page.refreshRoutingTargetForTesting();
        await waitUntil(() => h.page.currentVideoQa.value?.code == 80);
        expect(h.page.firstVideo.id, 80);
        final trace = h.events.sublist(marker);
        final opens = trace
            .where((event) => event.startsWith('open:'))
            .toList();
        expect(opens, isNotEmpty);
        expect(
          opens.where((event) => event.contains('8k1-1-30127')),
          isEmpty,
          reason: '零 open 127',
        );
      } finally {
        await h.close();
      }
    },
  );

  // T12：HDR 面板 + HDR 关闭 → 灰「已关闭 HDR 输出」（§1.7/X）。
  test(
    'T12: HDR panel with HDR off grays 126 with the hdrModeOff reason',
    () async {
      final h = _Harness();
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
          isTrue,
        );
        final eligibility = h.page.qualityEligibility(126);
        expect(eligibility.reason, VideoQualityIneligibility.hdrModeOff);
        expect(eligibility.message, hdrOffMessage);
        final accepted = await h.page.changeVideoQuality(126);
        expect(accepted, isFalse);
        expect(h.events, ['toast:$hdrOffMessage']);
        expect(h.players, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  // T13：fallback 空集三态（无 SDR 轨见 T6b；此处覆盖显式 require 下能力失败
  // 与 SDR 轨被拒）：提示、不静默、不崩、不重开。
  test('T13: empty fallback with require(sdr) options and a failed query toasts without crashing', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: false);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      await h.setupHdrOff();
      // 第一轮正常发布；然后让 source query 失败（unknown selection +
      // require(sdr) → SDR 轨也因缺少证据被拒）。
      expect(
        await h.page.probeRoutingForTesting(
          playUrlOf([item, sdr1080()]),
          1,
        ),
        isTrue,
      );
      await openLegacyPlaying126(h, item);
      h.caps.failSourceQuery = true;
      expect(
        await h.page.probeRoutingForTesting(
          playUrlOf([item, sdr1080()]),
          2,
        ),
        isTrue,
        reason: 'selection 进入 unknown',
      );
      h.owner.hdrDisplaySupportsHdr.value = false;
      h.owner.onHdrDisplayChanged!(false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      debugPrint(
        'T13 DEBUG events=${h.events} qa=${h.page.currentVideoQa.value?.code}',
      );
      await waitUntil(
        () => h.events.contains('toast:当前显示器不支持 HDR，且没有可播放的 SDR 画质'),
      );
      expect(h.page.currentVideoQa.value?.code, 126, reason: '不静默降级也不崩');
    } finally {
      await h.close();
    }
  });

  // T14：旧 query / 旧点击被新 revision 淘汰 → 不发布成功、不 toast。
  test('T14: a click superseded by a newer revision fails silently', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
        isTrue,
      );
      h.caps.armGateOnNextQuery = true;
      final click = h.page.changeVideoQuality(126);
      await h.caps.heldQueryStarted.future;
      // 点击仍在等被门控的查询。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // 新 revision 的 probe 完成发布，淘汰旧 serial。
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 2),
        isTrue,
      );
      h.caps.heldQueryGate.complete();
      final accepted = await click;
      expect(accepted, isFalse, reason: '陈旧 probe：不提示、不报成功');
      expect(h.events.where((event) => event.startsWith('toast:')), isEmpty);
      expect(h.players, isEmpty);
      expect(h.openBackend.plans, isEmpty);
    } finally {
      await h.close();
    }
  });

  // T15（替代断言）：两个菜单 Widget 的视觉/点击无法在宿主 widget-test（见
  // 报告）；这里断言 Widget 消费的契约：eligibility 语义 + 刷新信号。
  test('T15: eligibility contract and menu refresh revision bumps', () async {
    final h = _Harness();
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: false);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    try {
      final revisionBefore = h.page.videoQualityMenuRevision.value;
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
        isTrue,
      );
      expect(h.page.videoQualityMenuRevision.value, revisionBefore + 1);
      // 两个菜单都按 enabled 决定视觉置灰，点击统一进入 changeVideoQuality。
      expect(h.page.qualityEligibility(126).enabled, isFalse);
      expect(h.page.qualityEligibility(80).enabled, isTrue);
      final revisionAfterProbe = h.page.videoQualityMenuRevision.value;
      h.page.invalidateRouteOptionsForTesting(
        EffectiveVideoRouteOptions.resolve(),
      );
      expect(h.page.videoQualityMenuRevision.value, revisionAfterProbe + 1);
    } finally {
      await h.close();
    }
  });

  // T16：路由 seam=false（默认 Android Session 的窄用例）：首次 false 回调
  // 早于 data 赋值不抛、面板无 HDR 时菜单照旧灰。真正的非 Android 路由面
  // 准入由 R2-b/R2-c 覆盖；macOS 8K 由既有套件覆盖。
  test(
    'T16: routing seam false keeps the guard order and the SDR panel gray (default session)',
    () async {
      final h = _Harness()
        ..setupPage(
          firstVideo: dv126(),
          displayHdr: false,
          routingPlatformIsAndroid: false,
        )
        ..installCaps(messenger);
      try {
        expect(() => h.owner.onHdrDisplayChanged!(false), returnsNormally);
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([dv126(), sdr1080()]),
            1,
          ),
          isTrue,
        );
        expect(
          h.page.qualityEligibility(126).reason,
          VideoQualityIneligibility.displayHdrUnsupported,
        );
      } finally {
        await h.close();
      }
    },
  );

  // T18：点击成功时点——open 完成之前 changeVideoQuality 不返回 true。
  test(
    'T18: changeVideoQuality resolves only after the real open completes',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
          isTrue,
        );
        h.openBackend.gateOpen = true;
        final click = h.page.changeVideoQuality(80);
        var clickSettled = false;
        unawaited(click.whenComplete(() => clickSettled = true));
        await h.openBackend.openStarted.future;
        // 开源被门控挂起：此时点击绝不能完成（否则菜单 toast 会早于开源）。
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(clickSettled, isFalse, reason: '开源完成前点击不得返回成功');
        expect(h.players.last.opened, isEmpty, reason: 'open 尚未放行');
        h.openBackend.openGate.complete();
        expect(await click, isTrue);
        expect(h.players.last.opened, hasLength(1));
        expect(h.page.currentVideoQa.value?.code, 80);
      } finally {
        await h.close();
      }
    },
  );

  // T19：非 Android 路由面（无 probe、serial 不动）——revision/serial 复核
  // 不得误杀点击；各道守卫通过后进入真实开源（此处由抛错的输出端口承接）。
  test(
    'T19: non-Android routing lets a normal click pass the pre-open guards',
    () async {
      final h = _Harness(androidSession: false)
        ..setupPage(firstVideo: sdr1080(), displayHdr: true)
        ..installCaps(messenger);
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([sdr1080()]), 1),
          isTrue,
        );
        // 守卫全部通过、点击返回成功；非 Android 的开源失败按播放器既有
        // 错误契约落 status（不向上抛），此处以 error status 证明确实进入
        // 了开源事务（守卫误杀时 click 会返回 false 且 status 不变）。
        final accepted = await h.page.changeVideoQuality(80);
        expect(accepted, isTrue);
        expect(h.page.currentVideoQa.value?.code, 80);
        expect(h.owner.dataStatus.value, DataStatus.error);
        expect(h.owner.hdrVideoSession.value, isNull);
      } finally {
        await h.close();
      }
    },
  );

  // R2-a：HDR 关闭下直接调用 updatePlayer()（模拟音质/codec 变更、页面
  // 恢复等入口）不得（重）开 126；收敛点 findVideoByQa 拒绝并走既有
  // 「资源不可用」处理。
  test(
    'R2-a: updatePlayer under HDR off refuses to reopen the 126 tier',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, sdr1080()]),
            1,
          ),
          isTrue,
        );
        h.owner.cacheVideoQa = 126;
        h.page.currentVideoQa.value = VideoQuality.fromCode(126);
        await h.page.updatePlayer();
        expect(
          h.events.where((event) => event.startsWith('toast:')),
          ['toast:当前画质资源不可用'],
        );
        expect(h.players, isEmpty, reason: '未准入 rendition 不产生 open');
        expect(h.openBackend.plans, isEmpty);
      } finally {
        await h.close();
      }
    },
  );

  // R2-b：非 Android 旁路关闭——HDR 关闭下 updatePlayer 同样不得开 126，
  // SDR 档照常准入。
  test(
    'R2-b: non-Android routing honours the HDR-off admission for updatePlayer',
    () async {
      final item = dv126(codec: 'dvh1.08.07');
      final h = _Harness(fullStack: true, androidSession: false)
        ..setupPage(
          firstVideo: item,
          displayHdr: true,
          routingPlatformIsAndroid: false,
        )
        ..installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, sdr1080()]),
            1,
          ),
          isTrue,
          reason: '非 Android 路由面 probe 直通',
        );
        h.owner.cacheVideoQa = 126;
        h.page.currentVideoQa.value = VideoQuality.fromCode(126);
        await h.page.updatePlayer();
        expect(
          h.events.where((event) => event.startsWith('toast:')),
          ['toast:当前画质资源不可用'],
        );
        // SDR 档恒准入：切到 80 后 updatePlayer 正常开源（非 Android 的开源
        // 失败按播放器既有错误契约落 status，不向上抛）。
        h.page.currentVideoQa.value = VideoQuality.fromCode(80);
        await h.page.updatePlayer();
        expect(h.page.firstVideo.id, 80);
      } finally {
        await h.close();
      }
    },
  );

  // R2-c：非 Android + HDR 面板 + HDR 关闭 + 缓存 127 被 8K 门拒 + DASH 含
  // 126 与 SDR → 必须落到 SDR（8K fallback 携带 hdrModeOff）。
  test(
    'R2-c: non-Android, HDR off, 8K-gated 127 preference lands on SDR',
    () async {
      final eightK = VideoItem(
        id: 127,
        quality: VideoQuality.super8k,
        codecs: 'av01.0.17M.08',
        baseUrl: 'https://cdn.example/8k1-1-30127.m4s',
        width: 7680,
        height: 4320,
        bandWidth: 60000000,
      );
      final item = dv126(codec: 'dvh1.08.07');
      final h = _Harness(fullStack: true, androidSession: false)
        ..setupPage(
          firstVideo: eightK,
          displayHdr: true,
          routingPlatformIsAndroid: false,
        )
        ..installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([eightK, item, sdr1080()]),
            1,
          ),
          isTrue,
        );
        h.owner.cacheVideoQa = 127;
        await h.page.selectInitialSourceForTesting();
        expect(
          h.page.currentVideoQa.value?.code,
          80,
          reason: '8K 门拒 + HDR 关闭 → SDR',
        );
        expect(h.page.firstVideo.id, 80);
        expect(
          h.events.where((event) => event.startsWith('toast:')),
          isEmpty,
          reason: '缓存 127 非 HDR 编号：8K 降档不套 HDR 提示',
        );
      } finally {
        await h.close();
      }
    },
  );

  // B1：页面决策被更新配置淘汰（三态 superseded）→ L 不落地任何 Session
  // 副作用（不 setOptions、不重开、不改写最终 options）。
  test(
    'B1: a superseded settings decision performs no session side effects',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
          isTrue,
        );
        await openLegacyPlaying126(h, item);
        final marker = h.events.length;
        // A：HDR off（126 失去准入 → 决策将是降档重开），probe 被门控挂起。
        await h.setupHdrOff();
        h.caps.armGateOnNextQuery = true;
        final applyingA = h.owner.applyRoutePreferences();
        await h.caps.heldQueryStarted.future;
        // B：A 门控期间的新配置（decode 偏好）先完成——其回调在 HDR off 下
        // 已把页面降档到 80（恰一次 open）。
        await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto-safe');
        addTearDown(
          () => GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto'),
        );
        await h.owner.applyRoutePreferences();
        expect(h.page.currentVideoQa.value?.code, 80);
        final finalOptions = h.owner.dataSource.routeOptions;
        expect(
          h.events.sublist(marker).where((event) => event.startsWith('open:')),
          hasLength(1),
        );
        // 释放 A：其 probe 已被 B 淘汰 → superseded → 无新增副作用。
        h.caps.heldQueryGate.complete();
        await applyingA.timeout(const Duration(seconds: 5));
        final trace = h.events.sublist(marker);
        expect(trace.where((event) => event.startsWith('open:')), hasLength(1));
        expect(
          trace.where((event) => event.startsWith('configure:')),
          hasLength(1),
        );
        expect(
          identical(h.owner.dataSource.routeOptions, finalOptions),
          isTrue,
        );
      } finally {
        await h.close();
      }
    },
  );

  // B1(b)：决策挂起期间走页面拆除（releaseRoutingForTesting：解绑回调、
  // 推进 serial 并 dispose owner）→ 决策被淘汰，无副作用、不崩溃。
  test('B1(b): tearing down the page routing during a held decision retires it silently', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
        isTrue,
      );
      await openLegacyPlaying126(h, item);
      final marker = h.events.length;
      await h.setupHdrOff();
      h.caps.armGateOnNextQuery = true;
      final applyingA = h.owner.applyRoutePreferences();
      await h.caps.heldQueryStarted.future;
      // 生产拆除路径：解绑回调并推进 serial，挂起中的 probe 随即失效。
      h.page.releaseRoutingForTesting();
      h.caps.heldQueryGate.complete();
      await applyingA.timeout(const Duration(seconds: 5));
      expect(
        h.events.sublist(marker).where((event) => event.startsWith('open:')),
        isEmpty,
      );
      expect(
        h.events
            .sublist(marker)
            .where((event) => event.startsWith('configure:')),
        isEmpty,
      );
    } finally {
      await h.close(skipOwnerDispose: true);
    }
  });

  // B1(c)：决策挂起期间数据 revision 变化（换源）→ 决策被淘汰，无副作用。
  test(
    'B1(c): a data-revision change during a held decision retires it silently',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
          isTrue,
        );
        await openLegacyPlaying126(h, item);
        final marker = h.events.length;
        await h.setupHdrOff();
        h.caps.armGateOnNextQuery = true;
        final applyingA = h.owner.applyRoutePreferences();
        await h.caps.heldQueryStarted.future;
        // 换源：新的数据 revision 与新 DASH（旧 probe 全部失效）。
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, sdr1080()]),
            2,
          ),
          isTrue,
        );
        h.caps.heldQueryGate.complete();
        await applyingA.timeout(const Duration(seconds: 5));
        expect(
          h.events.sublist(marker).where((event) => event.startsWith('open:')),
          isEmpty,
        );
        expect(
          h.events
              .sublist(marker)
              .where((event) => event.startsWith('configure:')),
          isEmpty,
        );
      } finally {
        await h.close();
      }
    },
  );

  // B2(published)：门控在 backend.open——此时 Session 已发布（publishIfCurrent
  // 先于 open），设置变化走的是已有 Session 的 setOptions（keep-current），
  // 随后排空旧 open、重开一次。保留为「已发布 Session 的 keep-current
  // setOptions 路径」；未发布边界由下一条 B2 用例行使。
  test('B2(published): a settings change on a published session keeps current and reopens once', () async {
    final item = sdr1080();
    final h = _Harness(fullStack: true)
      ..setupPage(firstVideo: item, displayHdr: true)
      ..installCaps(messenger)
      ..owner.onVideoViewMounted();
    try {
      expect(await h.page.probeRoutingForTesting(playUrlOf([item]), 1), isTrue);
      h.owner.cacheVideoQa = 80;
      h.page.currentVideoQa.value = VideoQuality.fromCode(80);
      h.openBackend.gateOpen = true;
      final opening = h.page.updatePlayer();
      await h.openBackend.openStarted.future;
      // open 已启动 → 已发布：本用例的设置变化落在已发布 Session 上。
      expect(h.owner.videoPlayerController, isNotNull);
      expect(h.owner.hdrVideoSession.value, isNotNull);
      // decode 偏好变化（80 仍准入 → keep-current）。
      await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto-safe');
      addTearDown(
        () => GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto'),
      );
      final applying = h.owner.applyRoutePreferences();
      h.openBackend.openGate.complete();
      await opening.timeout(const Duration(seconds: 5));
      await applying.timeout(const Duration(seconds: 5));
      // 恰好一次「有效」新 open：携带最新 options（dataSource.routeOptions）。
      final opens = h.events
          .where((event) => event.startsWith('open:'))
          .toList();
      expect(opens, hasLength(2), reason: '已发布路径：首开 + 新 options 重开');
      expect(
        h.openBackend.plans.last.options,
        same(h.owner.dataSource.routeOptions),
        reason: '有效 open 携带最新 options',
      );
      expect(opens.last, contains('sdr1-1-30112'));
      expect(h.owner.videoPlayerController, isNotNull);
      expect(h.owner.dataStatus.value, DataStatus.loaded);
      expect(h.owner.hdrVideoSession.value, isNotNull);
    } finally {
      await h.close();
    }
  });

  // B2：网络首开**未发布**期间（门控在 `_initPlayer` 的目标能力查询——
  // publishIfCurrent 之前的首个真实 await）发生仍准入的 decode 偏好变化 →
  // 行使 L 的 unpublished 分支：排空旧初始化（旧 Player 释放、从未发布、
  // 从未 open）后经 ensureRouteSourceOptions 以新 options 重开既有 intent，
  // 恰一次有效 open，最终 loaded/已发布。
  test(
    'B2: a settings change during an unpublished network first-open lands exactly one valid open',
    () async {
      final item = sdr1080();
      final h = _Harness(fullStack: true)
        ..setupPage(firstVideo: item, displayHdr: true)
        ..installCaps(messenger)
        ..owner.onVideoViewMounted();
      try {
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([item]), 1),
          isTrue,
        );
        h.owner.cacheVideoQa = 80;
        h.page.currentVideoQa.value = VideoQuality.fromCode(80);
        // 门控位于发布之前：`_initPlayer` 的面板能力查询。
        h.caps.armGateOnNextPanelQuery = true;
        final opening = h.page.updatePlayer();
        await h.caps.heldPanelQueryStarted.future;
        // 未发布边界：设置变化到达时首开尚未发布任何 Player/Session。
        expect(h.owner.videoPlayerController, isNull);
        expect(h.owner.hdrVideoSession.value, isNull);
        // decode 偏好变化（80 仍准入 → keep-current，但无已发布会话）。
        await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto-safe');
        addTearDown(
          () => GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto'),
        );
        final applying = h.owner.applyRoutePreferences();
        h.caps.heldPanelQueryGate.complete();
        await opening.timeout(const Duration(seconds: 5));
        await applying.timeout(const Duration(seconds: 5));
        // 旧候选从未发布、从未 open：唯一 open 来自重开，且携带最新 options。
        expect(h.players, hasLength(2), reason: '旧初始化 Player + 重开 Player');
        expect(h.players.first.disposed, isTrue, reason: '旧 Player 已清理');
        expect(h.players.first.opened, isEmpty, reason: '旧候选从未 open');
        final opens = h.events
            .where((event) => event.startsWith('open:'))
            .toList();
        expect(opens, hasLength(1), reason: '门控位于发布前：旧初始化未抵达 open');
        expect(opens.single, contains('sdr1-1-30112'));
        expect(
          h.openBackend.plans.single.options,
          same(h.owner.dataSource.routeOptions),
          reason: '有效 open 携带最新 options',
        );
        expect(h.owner.videoPlayerController, same(h.players.last));
        expect(h.owner.dataStatus.value, DataStatus.loaded);
        expect(h.owner.hdrVideoSession.value, isNotNull);
      } finally {
        await h.close();
      }
    },
  );

  // B3-a：直接调用生产 playerInit()（页面恢复/首次手动播放形态）——HDR 关闭
  // 下旧 firstVideo=126 被准入降档到 SDR 后才提交 open。
  test('B3-a: direct playerInit under HDR off downgrades the legacy 126 firstVideo to SDR', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: true);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      await h.setupHdrOff();
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
        isTrue,
      );
      h.owner.cacheVideoQa = 126;
      h.page
        ..firstVideo = item
        ..videoUrl = item.baseUrl!
        ..currentVideoQa.value = VideoQuality.fromCode(126);
      await h.page.playerInit();
      expect(h.page.firstVideo.id, 80);
      expect(h.page.currentVideoQa.value?.code, 80);
      final opens = h.events
          .where((event) => event.startsWith('open:'))
          .toList();
      expect(opens, hasLength(1));
      expect(opens.single, contains('sdr1-1-30112'));
    } finally {
      await h.close();
    }
  });

  // B3-b：SDR 面板 + 旧 126 → 同样降档。
  test('B3-b: direct playerInit on an SDR panel downgrades the legacy 126 firstVideo', () async {
    final h = _Harness(fullStack: true);
    final item = dv126(codec: 'dvh1.08.07');
    h.setupPage(firstVideo: item, displayHdr: false);
    h.page.setDoviSniffForTesting((item) async => null);
    h.installCaps(messenger);
    h.owner.onVideoViewMounted();
    try {
      expect(
        await h.page.probeRoutingForTesting(playUrlOf([item, sdr1080()]), 1),
        isTrue,
      );
      h.owner.cacheVideoQa = 126;
      h.page
        ..firstVideo = item
        ..videoUrl = item.baseUrl!
        ..currentVideoQa.value = VideoQuality.fromCode(126);
      await h.page.playerInit();
      expect(h.page.firstVideo.id, 80);
      expect(h.page.currentVideoQa.value?.code, 80);
      expect(
        h.events.where((event) => event.startsWith('open:')),
        hasLength(1),
      );
    } finally {
      await h.close();
    }
  });

  // B3-c：无任何 admitted 轨 → 明确拒绝并 return，零 configure/open。
  test(
    'B3-c: direct playerInit with no admitted track refuses without opening',
    () async {
      final h = _Harness(fullStack: true);
      final item = dv126(codec: 'dvh1.08.07');
      h.setupPage(firstVideo: item, displayHdr: true);
      h.page.setDoviSniffForTesting((item) async => null);
      h.installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(playUrlOf([item]), 1),
          isTrue,
        );
        h.owner.cacheVideoQa = 126;
        h.page
          ..firstVideo = item
          ..videoUrl = item.baseUrl!
          ..currentVideoQa.value = VideoQuality.fromCode(126);
        await h.page.playerInit();
        expect(
          h.events.where((event) => event.startsWith('toast:')),
          ['toast:当前解码或 HDR 输出路径不支持该画质，已取消打开'],
        );
        expect(h.players, isEmpty);
        expect(h.openBackend.plans, isEmpty);
        expect(h.page.currentVideoQa.value?.code, 126);
      } finally {
        await h.close();
      }
    },
  );

  // B3-d：macOS 8K 门形态（非 Android 路由面 + 宿主 macOS 使门生效）+ HDR
  // 关闭 + 旧 firstVideo=126 + DASH{126, 127(AV1 硬解未确认), 80} →
  // playerInit 兜底不得绕过 8K 资格门：开 80，127 零 configure/open。
  // 非 Android 面不经会话 open，"open 127"以 fake Player 的 opened 列表为准。
  test(
    'B3-d: the playerInit 8K fallback stays behind the hardware gate and opens 80',
    () async {
      final item = dv126(codec: 'dvh1.08.07');
      final h = _Harness(fullStack: true, androidSession: false)
        ..setupPage(
          firstVideo: item,
          displayHdr: true,
          routingPlatformIsAndroid: false,
        )
        ..installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            playUrlOf([item, eightKTrack('av01.0.17M.08'), sdr1080()]),
            1,
          ),
          isTrue,
          reason: '非 Android 路由面 probe 直通',
        );
        h.owner.cacheVideoQa = 126;
        h.page
          ..firstVideo = item
          ..videoUrl = item.baseUrl!
          ..currentVideoQa.value = VideoQuality.fromCode(126);
        // 未注入探测结果：127 的 AV1 处于 probe-pending（fail-closed）。
        await h.page.playerInit();
        expect(h.page.firstVideo.id, 80);
        expect(h.page.currentVideoQa.value?.code, 80);
        expect(h.players, hasLength(1));
        final opened = h.players.single.opened.cast<Media>();
        expect(opened, hasLength(1));
        expect(opened.single.uri, contains('sdr1-1-30112'));
        expect(opened.single.uri, isNot(contains('8k1-1-30127')));
        expect(h.openBackend.plans, isEmpty, reason: '零 configure');
      } finally {
        await h.close();
      }
    },
  );

  // B3-e：同 B3-d 但 127 的 AV1 失败、HEVC 已确认硬解 → 兜底可以落 127，
  // 但具体 codec 必须与普通最终选源一致（仅已确认硬解的 HEVC，不得 AV1）。
  test(
    'B3-e: the playerInit 8K fallback selects only the confirmed-hardware codec',
    () async {
      final item = dv126(codec: 'dvh1.08.07');
      final av1 = eightKTrack('av01.0.17M.08');
      final hevc = eightKTrack(
        'hev1.2.4.L183.B0',
        baseUrl: 'https://cdn.example/8k-hevc-1-1-30127.m4s',
      );
      final h = _Harness(fullStack: true, androidSession: false)
        ..setupPage(
          firstVideo: item,
          displayHdr: true,
          routingPlatformIsAndroid: false,
        )
        ..installCaps(messenger);
      h.owner.onVideoViewMounted();
      try {
        await h.setupHdrOff();
        expect(
          await h.page.probeRoutingForTesting(
            // HEVC 在前：旧实现的兜底 reduce 对同质量值保留**后一**轨，
            // 该顺序下旧实现会选回未授权的 AV1。
            playUrlOf([item, hevc, av1, sdr1080()]),
            1,
          ),
          isTrue,
          reason: '非 Android 路由面 probe 直通',
        );
        h.page.seedDecodeCapabilitiesForTesting([
          VideoDecodeCapability.fromTrack(av1).copyWith(
            hardwareSupported: false,
            reason: 'test-av1-hardware-unavailable',
          ),
          VideoDecodeCapability.fromTrack(hevc).copyWith(
            hardwareSupported: true,
            reason: 'test-hevc-hardware-confirmed',
          ),
        ]);
        h.owner.cacheVideoQa = 126;
        h.page
          ..firstVideo = item
          ..videoUrl = item.baseUrl!
          ..currentVideoQa.value = VideoQuality.fromCode(126);
        await h.page.playerInit();
        expect(h.page.firstVideo.id, 127);
        expect(h.page.firstVideo.codecs, 'hev1.2.4.L183.B0');
        expect(h.page.currentVideoQa.value?.code, 127);
        expect(h.players, hasLength(1));
        final opened = h.players.single.opened.cast<Media>();
        expect(opened, hasLength(1));
        expect(opened.single.uri, contains('8k-hevc-1-1-30127'));
        expect(opened.single.uri, isNot(contains('8k1-1-30127')));
      } finally {
        await h.close();
      }
    },
  );
}

/// 前缀匹配器：toast sink 记录的是完整文案，断言只关心来源路径时用前缀。
class PrefixMatcher extends Matcher {
  const PrefixMatcher(this.prefix);

  final String prefix;

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) =>
      item is String && item.startsWith(prefix);

  @override
  Description describe(Description description) =>
      description.add('a string starting with ').addDescriptionOf(prefix);
}
