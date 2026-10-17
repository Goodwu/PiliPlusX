import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show min;
import 'dart:ui';

import 'package:media_kit_video/media_kit_video.dart'
    show VideoOutputTarget, EffectiveVideoRouteOptions;
import 'package:piliplus/plugin/pl_player/dovi_sniff.dart';
import 'package:piliplus/plugin/pl_player/hdr_output.dart';
import 'package:piliplus/plugin/pl_player/models/hdr.dart' show HdrMode;
import 'package:piliplus/plugin/pl_player/source_selection.dart';
import 'package:piliplus/common/style.dart';
import 'package:piliplus/common/widgets/pair.dart';
import 'package:piliplus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:piliplus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:piliplus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:piliplus/grpc/dm.dart';
import 'package:piliplus/http/browser_ua.dart';
import 'package:piliplus/http/fav.dart';
import 'package:piliplus/http/init.dart';
import 'package:piliplus/http/loading_state.dart';
import 'package:piliplus/http/user.dart';
import 'package:piliplus/http/video.dart';
import 'package:piliplus/models/common/account_type.dart';
import 'package:piliplus/models/common/sponsor_block/action_type.dart';
import 'package:piliplus/models/common/sponsor_block/post_segment_model.dart';
import 'package:piliplus/models/common/sponsor_block/segment_model.dart';
import 'package:piliplus/models/common/sponsor_block/segment_type.dart';
import 'package:piliplus/models/common/video/audio_quality.dart';
import 'package:piliplus/models/common/video/source_type.dart';
import 'package:piliplus/models/common/video/video_decode_type.dart';
import 'package:piliplus/models/common/video/video_quality.dart';
import 'package:piliplus/models/common/video/video_type.dart';
import 'package:piliplus/models/video/play/url.dart';
import 'package:piliplus/models_new/download/bili_download_entry_info.dart';
import 'package:piliplus/models_new/media_list/media_list.dart';
import 'package:piliplus/models_new/pgc/pgc_info_model/result.dart';
import 'package:piliplus/models_new/video/video_detail/data.dart';
import 'package:piliplus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:piliplus/models_new/video/video_detail/page.dart';
import 'package:piliplus/models_new/video/video_pbp/data.dart';
import 'package:piliplus/models_new/video/video_play_info/subtitle.dart';
import 'package:piliplus/models_new/video/video_stein_edgeinfo/data.dart';
import 'package:piliplus/pages/audio/view.dart';
import 'package:piliplus/pages/common/publish/publish_route.dart';
import 'package:piliplus/pages/search/widgets/search_text.dart';
import 'package:piliplus/pages/sponsor_block/block_mixin.dart';
import 'package:piliplus/pages/video/download_panel/view.dart';
import 'package:piliplus/pages/video/introduction/pgc/controller.dart';
import 'package:piliplus/pages/video/introduction/ugc/controller.dart';
import 'package:piliplus/pages/video/local_diagnostic/policy.dart';
import 'package:piliplus/pages/video/medialist/view.dart';
import 'package:piliplus/pages/video/note/view.dart';
import 'package:piliplus/pages/video/post_panel/view.dart';
import 'package:piliplus/pages/video/send_danmaku/view.dart';
import 'package:piliplus/pages/video/widgets/header_control.dart';
import 'package:piliplus/pages/video/video_quality_eligibility.dart';
import 'package:piliplus/platform/platform_features.dart';
import 'package:piliplus/plugin/pl_player/controller.dart';
import 'package:piliplus/plugin/pl_player/models/data_source.dart';
import 'package:piliplus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:piliplus/plugin/pl_player/models/play_status.dart';
import 'package:piliplus/services/download/download_service.dart';
import 'package:piliplus/utils/accounts.dart';
import 'package:piliplus/utils/connectivity_utils.dart';
import 'package:piliplus/utils/extension/context_ext.dart';
import 'package:piliplus/utils/extension/iterable_ext.dart';
import 'package:piliplus/utils/extension/nested_scroll_ext.dart';
import 'package:piliplus/utils/extension/num_ext.dart';
import 'package:piliplus/utils/extension/size_ext.dart';
import 'package:piliplus/utils/page_utils.dart';
import 'package:piliplus/utils/platform_utils.dart';
import 'package:piliplus/utils/storage.dart';
import 'package:piliplus/utils/storage_pref.dart';
import 'package:piliplus/utils/theme_utils.dart';
import 'package:piliplus/utils/utils.dart';
import 'package:piliplus/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart' show Options;
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart'
    show ExtendedNestedScrollViewState;
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

class VideoDetailController extends GetxController
    with GetTickerProviderStateMixin, BlockMixin {
  /// 路由传参
  late final Map args;
  late String bvid;
  late int aid;
  late final RxInt cid;
  int? epId;
  int? seasonId;
  int? pgcType;
  late final String heroTag;
  late final RxString cover;

  // 视频类型 默认投稿视频
  late final VideoType videoType;
  @override
  late final isUgc = videoType == VideoType.ugc;
  VideoType? _actualVideoType;

  // 页面来源 稍后再看 收藏夹
  late bool isPlayAll;
  late SourceType sourceType;
  late BiliDownloadEntryInfo entry;
  late bool isFileSource;
  bool isLocalVideoDiagnostic = false;
  late bool _mediaDesc = false;
  late final RxList<MediaListItemModel> mediaList = <MediaListItemModel>[].obs;
  late String watchLaterTitle;

  /// tabs相关配置
  late TabController tabCtr;

  // 请求返回的视频信息
  /// DASH 响应的可空影子：面板回调可能早于首个响应到达（请求前的
  /// refresh 会同步触发 `_onHdrDisplayChanged`），回调读取 [data] 前必须
  /// 先看 [_hasPlaybackData]，不允许用 try/catch 吞 LateInitializationError。
  PlayUrlModel? _playbackData;
  PlayUrlModel get data => _playbackData!;
  bool get _hasPlaybackData => _playbackData != null;
  set data(PlayUrlModel value) => _playbackData = value;
  final RxBool videoState = false.obs;

  /// 播放器配置 画质 音质 解码格式
  final Rxn<VideoQuality> currentVideoQa = Rxn<VideoQuality>();

  /// Advances whenever a new part's DASH response replaces [data]. Menus read
  /// this explicitly because a same-qn P1 -> P2 transition otherwise leaves
  /// them closed over the previous response.
  final RxInt videoQualityMenuRevision = 0.obs;
  int _playbackDataRevision = 0;
  VideoOutputTarget _videoOutputTarget =
      const VideoOutputTarget.applicationView();
  FlutterView? _routingView;
  int? _routingDisplayId;
  int _routingQuerySerial = 0;
  DashRouteSelection? _routeSelection;
  EffectiveVideoRouteOptions? _routeOptions;
  int _routeOptionsRevision = 0;

  /// DV003/B2: sniffed DOVI facts keyed by rendition identity
  /// (playUrlDataRevision + cid + baseUrl), NOT by VideoSourceSpec.key —
  /// the spec key describes codec/geometry only and two different videos can
  /// collide on it. The generation captured when a sniff starts guards the
  /// write: a result for a superseded playurl revision is dropped instead of
  /// polluting the cache for the next rendition.
  final Map<String, DoviFacts> _doviFactsCache = {};
  final Map<String, Future<DoviFacts?>> _doviFactsInFlight = {};

  /// Outer bound on one shared sniff task: the same budget a raw
  /// sniffDoviInitSegment call gives itself, so a wedged fetch cannot hold
  /// the route probe open past it.
  static const Duration _doviSniffBudget = Duration(seconds: 4);

  /// DV003 narrow test seam: swaps only the sniff transport; key derivation,
  /// in-flight sharing and the cache/generation handling stay on the
  /// production path.
  Future<DoviFacts?> Function(VideoItem) _doviSniff = sniffDoviInitSegment;

  @visibleForTesting
  void setDoviSniffForTesting(Future<DoviFacts?> Function(VideoItem) sniff) {
    _doviSniff = sniff;
  }

  /// 路由相关平台判定的最窄测试 seam：生产默认 `Platform.isAndroid`，生产
  /// 零变化；宿主测试注入 true 后才能命中 Android 专属分支。
  bool _routingPlatformIsAndroid = Platform.isAndroid;

  @visibleForTesting
  set routingPlatformIsAndroidForTesting(bool value) {
    _routingPlatformIsAndroid = value;
  }

  /// 本策略涉及的页面 toast 的最窄测试观察点：生产默认直接走 SmartDialog；
  /// 宿主测试没有 overlay，注入 sink 后改为按序记录文案与相对时点。
  void Function(String message)? _pageToastSink;

  @visibleForTesting
  set pageToastSinkForTesting(void Function(String message)? sink) {
    _pageToastSink = sink;
  }

  void _toast(String message) {
    final sink = _pageToastSink;
    if (sink != null) {
      sink(message);
      return;
    }
    SmartDialog.showToast(message);
  }

  late final void Function(EffectiveVideoRouteOptions)
  _routeInvalidatedCallback = _invalidateRouteOptions;
  late final Future<RouteOptionsDecision> Function(EffectiveVideoRouteOptions)
  _routeChangedCallback = _refreshRouteOptions;

  void _invalidateRouteOptions(EffectiveVideoRouteOptions options) {
    ++_routeOptionsRevision;
    ++_routingQuerySerial;
    _routeOptions = options;
    _routeSelection = null;
    videoQualityMenuRevision.value++;
  }

  /// 设置变化重开（E1，R1/B1）：在 L 的任何 Session 副作用之前完成
  /// rendition 决策，三态语义见 [RouteOptionsDecision]。
  Future<RouteOptionsDecision> _refreshRouteOptions(
    EffectiveVideoRouteOptions options,
  ) async {
    if (isClosed || !identical(_routeOptions, options)) {
      return RouteOptionsDecision.superseded;
    }
    if (isFileSource) {
      // 文件源没有 rendition 决策，由 ensureRouteSourceOptions 收敛：尚无
      // 已发布会话时它执行 intent.reopen（此时 L 必须跳过 setOptions，否则
      // 会对重开后的 source 再开一次）；已有会话时 setOptions 原地生效。
      final hadSession = plPlayerController.hdrVideoSession.value != null;
      await plPlayerController.ensureRouteSourceOptions(options);
      return hadSession
          ? RouteOptionsDecision.keepCurrent
          : RouteOptionsDecision.reopened;
    }
    final revision = _playbackDataRevision;
    final configRevision = _routeOptionsRevision;
    if (revision == 0 ||
        !await _probeRoutingCapabilities(revision) ||
        isClosed ||
        revision != _playbackDataRevision ||
        configRevision != _routeOptionsRevision) {
      // probe 已被更新的 serial/configRevision/数据淘汰：交 L 的时效复核
      // 直接丢弃本次决策。
      return RouteOptionsDecision.superseded;
    }
    final current = currentVideoQa.value;
    if (current != null &&
        _openAdmitsQuality(current.code) &&
        findVideoByQa(current.code) != null) {
      return RouteOptionsDecision.keepCurrent;
    }
    // 先选轨、再提交状态（复审 4）：候选经共用兜底选轨（同一 8K 资格门），
    // 选不出可播轨时不写入虚假降档状态，按既有空集语义停播。
    final fallback = _pickFallbackSdrTrack();
    if (fallback == null) {
      await plPlayerController.stopForRouteOptions('当前路由配置没有可播放资源');
      return RouteOptionsDecision.reopened;
    }
    currentVideoQa.value = fallback.quality;
    plPlayerController.cacheVideoQa = fallback.quality.code;
    await updatePlayer();
    return RouteOptionsDecision.reopened;
  }

  @visibleForTesting
  Future<bool> probeRoutingForTesting(PlayUrlModel data, int revision) {
    this.data = data;
    _playbackDataRevision = revision;
    plPlayerController
      ..onRouteOptionsInvalidated = _routeInvalidatedCallback
      ..onRouteOptionsChanged = _routeChangedCallback;
    return _probeRoutingCapabilities(revision);
  }

  /// `probeRoutingForTesting` 不覆盖 HDR 面板回调的绑定；这是最窄的
  /// 测试入口，绑定后经 owner 的 `onHdrDisplayChanged` 触发降级链路。
  @visibleForTesting
  void bindHdrDisplayCallbackForTesting() {
    plPlayerController.onHdrDisplayChanged = _hdrDisplayChangedCallback;
  }

  @visibleForTesting
  Future<void> refreshRoutingTargetForTesting() => _refreshRoutingTarget();

  @visibleForTesting
  Future<void> selectInitialSourceForTesting({
    bool autoFullScreenFlag = false,
  }) => _selectInitialSource(autoFullScreenFlag: autoFullScreenFlag);

  @visibleForTesting
  void invalidateRouteOptionsForTesting(EffectiveVideoRouteOptions options) =>
      _invalidateRouteOptions(options);

  @visibleForTesting
  DashRouteSelection? get routingSelectionForTesting => _routeSelection;

  @visibleForTesting
  void releaseRoutingForTesting() {
    _unbindRoutingCallbacks();
    plPlayerController.dispose();
  }

  /// Called by the owning page, not by a Player or a guessed OS display ID.
  void bindOutputView(FlutterView view) {
    if (identical(view, _routingView) && _routingDisplayId == view.display.id) {
      return;
    }
    _routingView = view;
    _routingDisplayId = view.display.id;
    _videoOutputTarget = VideoOutputTarget.flutterView(view);
    plPlayerController.videoOutputTarget = _videoOutputTarget;
    _routeSelection = null;
    if (!_routingPlatformIsAndroid ||
        _playbackDataRevision == 0 ||
        isQuerying ||
        isFileSource) {
      return;
    }
    unawaited(_refreshRoutingTarget());
  }

  Future<void> _refreshRoutingTarget() async {
    final revision = _playbackDataRevision;
    final configRevision = _routeOptionsRevision;
    if (!await _probeRoutingCapabilities(revision) || isClosed) return;
    await plPlayerController.refreshHdrDisplayCapabilities();
    if (revision != _playbackDataRevision ||
        configRevision != _routeOptionsRevision ||
        isClosed ||
        isQuerying) {
      return;
    }
    // Re-open through the ordinary source transaction, which retains position.
    // An old target snapshot never authorizes the new output.
    final current = currentVideoQa.value;
    if (current == null) return;
    if (!_openAdmitsQuality(current.code) ||
        findVideoByQa(current.code) == null) {
      // 先选轨、再提交状态（复审 4）：共用兜底选轨（同一 8K 资格门），
      // 选不出可播轨时不写入虚假降档状态，按既有空集语义停播。
      final fallback = _pickFallbackSdrTrack();
      if (fallback == null) {
        await plPlayerController.stopForRouteOptions('当前显示目标没有可播放路由');
        return;
      }
      currentVideoQa.value = fallback.quality;
      plPlayerController.cacheVideoQa = fallback.quality.code;
    }
    await updatePlayer();
  }

  /// 五个开源入口共用的 rendition 准入（§3.3/R2）：SDR 档在 Android 路由面
  /// 走逐轨路由判断、其它面恒准入；HDR 档在**所有**平台都必须满足面板能力
  /// 与用户 HDR 偏好——非 Android 面仅跳过规划器预测与逐轨路由（呈现由
  /// 会话在 open 时裁决）。require(sdr) 不再豁免 HDR 呈现检查。
  bool _openAdmits(VideoItem item) {
    if (!_isHdrQuality(item.id)) {
      if (!plPlayerController.usesAndroidRouting) return true;
      return _routeAllows(item);
    }
    if (!plPlayerController.hdrDisplaySupportsHdr.value || _hdrModeOff) {
      return false;
    }
    if (!plPlayerController.usesAndroidRouting) return true;
    if (!_routeAllows(item)) return false;
    return HdrOutputSelector.isHdrPresentable(
      (_routeSelection ?? DashRouteSelection.unknown(options: _routeOptions))
          .prediction(item),
    );
  }

  bool _openAdmitsQuality(int quality) =>
      _tracksForQuality(quality).any(_openAdmits);

  /// 降级/兜底共用的 SDR 选轨（复审 4）：候选 = 非 HDR ∧ [_openAdmits]，
  /// 先经与普通最终选源**同一** 8K 资格门（macOS 硬解确认——127 是 8K 但
  /// 非 HDR 编号，不过滤会直接绕门），取质量值最大的档位，再交回
  /// [findVideoByQa] 统一选定具体 codec（多 codec 8K 只会返回已确认硬解的
  /// 那条）。返回 null 表示没有可降级到的可播 SDR 轨；调用方（D 面板降级、
  /// E1/E2 重开兜底、playerInit 兜底）必须**先选轨、再提交状态**。
  VideoItem? _pickFallbackSdrTrack() {
    final admitted = tracksEligibleForPlayback(
      tracks: (data.dash?.video ?? const <VideoItem>[])
          .where((item) => !_isHdrQuality(item.id))
          .where(_openAdmits)
          .toList(),
      gateEightKWithHardware: PlatformFeatureSupport.isMacOS,
      decodeCapabilities: _decodeCapabilities,
    );
    if (admitted.isEmpty) return null;
    final quality = admitted
        .map((item) => item.quality.code)
        .reduce((a, b) => a > b ? a : b);
    return findVideoByQa(
      quality,
      setCodecs: true,
      requireConfirmedEightKHardware: true,
    );
  }

  bool _routeAllows(VideoItem item) =>
      !plPlayerController.usesAndroidRouting ||
      (_routeSelection ?? DashRouteSelection.unknown(options: _routeOptions))
          .allows(item);

  Future<bool> _probeRoutingCapabilities(int revision) async {
    if (!plPlayerController.usesAndroidRouting) return true;
    final request = plPlayerController.readRouteRequest();
    if (request.hasUnsupportedLegacyRequest) {
      await plPlayerController.stopForRouteOptions(request.unsupportedReason!);
      return false;
    }
    final options = _routeOptions ??= request.resolve();
    final configRevision = _routeOptionsRevision;
    final serial = ++_routingQuerySerial;
    _routeSelection = null;
    final doviFactsResolver = await _resolveDoviFacts();
    if (revision != _playbackDataRevision ||
        serial != _routingQuerySerial ||
        configRevision != _routeOptionsRevision ||
        !identical(options, _routeOptions)) {
      return false;
    }
    // A first FlutterView can attach while the initial query is outstanding.
    // Re-read that target once; do not publish a result for the previous one.
    for (var attempt = 0; attempt < 2; attempt++) {
      final target = _videoOutputTarget;
      final selection = await DashRouteSelection.query(
        tracks: data.dash?.video ?? const [],
        target: target,
        options: options,
        doviFactsResolver: doviFactsResolver,
      );
      if (isClosed ||
          revision != _playbackDataRevision ||
          serial != _routingQuerySerial ||
          configRevision != _routeOptionsRevision ||
          !identical(options, _routeOptions)) {
        return false;
      }
      if (!identical(target, _videoOutputTarget)) continue;
      _routeSelection = selection;
      // 面板标志只由 L 的 probe/事件链写入（§3.4）：selection.displayHdr
      // 的路由查询结果不覆写它——查询失败（_sources 为空 → null）会误灰
      // 能力正常的好面板。
      videoQualityMenuRevision.value++;
      return true;
    }
    return false;
  }

  /// DV003: Bilibili's Dolby Vision tier (126) carries no profile in its
  /// codec string, so the rendition's own initialization segment is sniffed
  /// (one bounded Range GET) to resolve the profile before route selection.
  /// Failures stay absent from the map: unknown-DV semantics then keep the
  /// tier gray instead of guessing. The key is the rendition identity —
  /// never VideoSourceSpec.key, which only describes codec/geometry and can
  /// collide across renditions.
  String _doviFactsKeyFor(
    VideoItem item, {
    required int revision,
    required int cid,
  }) => '$revision/$cid/${item.baseUrl}';

  String _doviFactsKey(VideoItem item) =>
      _doviFactsKeyFor(item, revision: _playbackDataRevision, cid: cid.value);

  /// DV005: the open-time hint reads the cache through the same rendition
  /// key the resolver writes, so a re-open of the current rendition reuses
  /// its container facts while a new revision/cid/track starts without an
  /// inherited hint.
  DoviFacts? get _initialDoviFacts => isLocalVideoDiagnostic
      ? null
      : _doviFactsCache[_doviFactsKey(firstVideo)];

  @visibleForTesting
  DoviFacts? get initialDoviFactsForTesting => _initialDoviFacts;

  /// One shared task per rendition key. Every caller awaits the same future
  /// instead of skipping, so a concurrent probe for this rendition receives
  /// the result rather than racing a duplicate request. The commit and the
  /// in-flight cleanup live inside the task: the write consumes only the
  /// timeout-wrapped future's result (a late raw-sniff completion is
  /// dropped), and the removal checks future identity so it never deletes a
  /// replacement task registered under the same key.
  Future<DoviFacts?> _sniffDoviTask(
    String key,
    VideoItem item,
    int revision,
    int cidValue,
  ) {
    final bounded = _sniffDoviBounded(item);
    final task = bounded.then<DoviFacts?>((facts) {
      // A result computed for this rendition must not poison a newer one.
      if (facts != null &&
          revision == _playbackDataRevision &&
          cidValue == cid.value) {
        _doviFactsCache[key] = facts;
      }
      return facts;
    });
    // The stored entry is this exact future: the cleanup only removes the
    // slot it still owns.
    late final Future<DoviFacts?> guarded;
    guarded = task.whenComplete(() {
      if (identical(_doviFactsInFlight[key], guarded)) {
        _doviFactsInFlight.remove(key);
      }
    });
    return guarded;
  }

  /// Bounded, never-throwing view of one sniff: a timeout or a failing
  /// transport is "no facts", not a failed probe.
  Future<DoviFacts?> _sniffDoviBounded(VideoItem item) async {
    try {
      // The timeout's onTimeout is runtime-checked against the reified type
      // argument of the sniff future; an injected sniff that never returns
      // null reifies Future<DoviFacts>, so the type is normalized first.
      final result =
          await _doviSniff(
                item,
              )
              .then<DoviFacts?>((facts) => facts)
              .timeout(
                _doviSniffBudget,
                onTimeout: () => null,
              );
      return result;
    } on Object {
      return null;
    }
  }

  /// DV003: resolves the DOVI facts of this rendition set's unresolved-DV
  /// tracks and returns a frozen resolver for route selection. The resolver
  /// binds the revision/cid captured here plus a snapshot of this round's
  /// entries, so a selection built now keeps judging exactly the rendition
  /// this probe was for even after the active identity or cache moved on.
  Future<DoviFacts? Function(VideoItem)> _resolveDoviFacts() async {
    final revision = _playbackDataRevision;
    final tracks = data.dash?.video ?? const <VideoItem>[];
    final roundKeys = <String>{};
    final tasks = <Future<DoviFacts?>>[];
    // cid is a page-argument field: renditions without an unresolved-DV
    // track never need it, matching the old per-track key derivation.
    int? roundCid;
    for (final item in tracks) {
      if (item.id != VideoQuality.dolbyVision.code) continue;
      if (DashRouteSelection.specification(item) == null) continue;
      if (item.baseUrl?.isNotEmpty != true) continue;
      final descriptor = HdrOutputSelector.descriptorFromDash(
        quality: item.id,
        codec: item.codecs,
      );
      if (descriptor?.hasUnresolvedDolbyVision != true) continue;
      roundCid ??= cid.value;
      final key = _doviFactsKeyFor(item, revision: revision, cid: roundCid);
      roundKeys.add(key);
      if (_doviFactsCache.containsKey(key)) continue;
      tasks.add(
        _doviFactsInFlight.putIfAbsent(
          key,
          () => _sniffDoviTask(key, item, revision, roundCid!),
        ),
      );
    }
    debugPrint(
      'DOVI_SNIFF pending=${tasks.length} cached=${_doviFactsCache.length}',
    );
    await Future.wait(tasks);
    final cidValue = roundCid;
    if (cidValue == null) return (_) => null;
    final Map<String, DoviFacts> snapshot = Map.unmodifiable(
      <String, DoviFacts>{
        for (final entry in _doviFactsCache.entries)
          if (roundKeys.contains(entry.key)) entry.key: entry.value,
      },
    );
    return (VideoItem item) =>
        snapshot[_doviFactsKeyFor(item, revision: revision, cid: cidValue)];
  }

  final Map<String, VideoDecodeCapability> _decodeCapabilities = {};

  /// 最窄测试注入：宿主打不到 `_probeEightKDecodeCapabilities` 的生产触发
  /// 点（真实 playurl 响应），8K 门相关用例以此摆放探测结果；键为
  /// [VideoDecodeCapability.key]，生产零行为变化。
  @visibleForTesting
  void seedDecodeCapabilitiesForTesting(
    Iterable<VideoDecodeCapability> capabilities,
  ) {
    _decodeCapabilities
      ..clear()
      ..addAll({
        for (final capability in capabilities) capability.key: capability,
      });
  }

  AudioQuality? currentAudioQa;
  // `findVideoByQa` is also the initial source selector. Give that first
  // transaction a safe preference before it has had a prior rendition from
  // which to inherit a codec; otherwise reading a late field aborts playback
  // before the 8K gate can fall back.
  VideoDecodeFormatType currentDecodeFormats = VideoDecodeFormatType.AVC;

  // 是否开始自动播放 存在多p的情况下，第二p需要为true
  final RxBool _autoPlay = Pref.autoPlayEnable.obs;

  final videoPlayerKey = GlobalKey();
  final childKey = GlobalKey<MiniScaffoldState>();

  final plPlayerController = PlPlayerController.getInstance()
    ..brightness.value = -1;
  late final void Function(bool) _hdrDisplayChangedCallback =
      _onHdrDisplayChanged;
  bool get setSystemBrightness => plPlayerController.setSystemBrightness;
  bool get removeSafeArea => plPlayerController.removeSafeArea;
  double get uiScale => plPlayerController.uiScale;

  late VideoItem firstVideo;
  String? videoUrl;
  String? audioUrl;
  Duration? defaultST;
  Duration? playedTime;
  String get playedTimePos {
    final pos = playedTime?.inMilliseconds;
    return pos == null || pos == 0 ? '' : '?t=${pos / 1000}';
  }

  // 亮度
  double? brightness;

  late final headerCtrKey = GlobalKey<TimeBatteryMixin>();

  Box setting = GStorage.setting;

  // 预设的解码格式
  late List<VideoDecodeFormatType> preferCodecs = Pref.preferCodecs;

  bool get showReply => isFileSource
      ? false
      : isUgc
      ? plPlayerController.showVideoReply
      : plPlayerController.showBangumiReply;

  bool get showRelatedVideo =>
      isFileSource ? false : plPlayerController.showRelatedVideo;

  ScrollController? introScrollCtr;
  ScrollController get effectiveIntroScrollCtr =>
      introScrollCtr ??= ScrollController();

  int? seasonCid;
  late final RxInt seasonIndex = 0.obs;

  PlayerStatus? playerStatus;

  late final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();
  late final RxBool isVertical;
  late final RxDouble scrollRatio = 0.0.obs;

  ScrollController? _scrollCtr;
  ScrollController get scrollCtr => _scrollCtr ??= ScrollController();

  late bool isExpanding = false;
  late bool isCollapsing = false;

  late double minVideoHeight;
  late double maxVideoHeight;
  late double videoHeight;
  late double animHeight;

  AnimationController? animController;
  AnimationController get animationController =>
      animController ??= (AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addListener(_animListener));

  void refreshPage() {
    scrollKey.currentState?.refresh();
  }

  void _animListener() {
    if (animationController.isForwardOrCompleted) {
      _calcAnimHeight();
      refreshPage();
    }
  }

  void _calcAnimHeight() {
    if (isExpanding) {
      animHeight = clampDouble(
        videoHeight * animationController.value,
        kToolbarHeight,
        videoHeight,
      );
    } else if (isCollapsing) {
      animHeight = clampDouble(
        maxVideoHeight -
            (maxVideoHeight - minVideoHeight) * animationController.value,
        minVideoHeight,
        maxVideoHeight,
      );
    }
  }

  void animToTop() {
    scrollKey.currentState?.animToTop();
  }

  bool _needAnimOnDimensionChanged(bool isVertical) {
    if (isFullScreen) {
      if (PlatformUtils.isMobile) {
        plPlayerController.changeOrientation(isVertical: isVertical);
      }
      return false;
    }
    return true;
  }

  @pragma('vm:notify-debugger-on-exception')
  void _setVideoHeight() {
    try {
      var width = firstVideo.width;
      var height = firstVideo.height;
      if (width == null || height == null) {
        if (isUgc && !isFileSource) {
          final ugcIntroCtr = Get.find<UgcIntroController>(tag: heroTag);
          final cid = this.cid.value;
          final part = ugcIntroCtr.videoDetail.value.pages?.firstWhereOrNull(
            (e) => e.cid == cid,
          );
          if (part != null) {
            final dimension = part.dimension!;
            width = dimension.width!;
            height = dimension.height!;
          } else {
            return;
          }
        } else {
          return;
        }
      }
      final isVertical = height > width;
      if (_scrollCtr?.hasClients != true) {
        videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.isVertical.value != isVertical) {
          this.isVertical.value = isVertical;
          _needAnimOnDimensionChanged(isVertical);
        }
        return;
      }
      if (this.isVertical.value != isVertical) {
        this.isVertical.value = isVertical;
        double videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.videoHeight != videoHeight) {
          if (videoHeight > this.videoHeight) {
            // current minVideoHeight
            if (_needAnimOnDimensionChanged(isVertical)) {
              isExpanding = true;
              animationController.forward(
                from: (minVideoHeight - scrollCtr.offset) / maxVideoHeight,
              );
            }
            this.videoHeight = maxVideoHeight;
          } else {
            // current maxVideoHeight
            final currentHeight = (maxVideoHeight - scrollCtr.offset)
                .toPrecision(2);
            double minVideoHeightPrecise = minVideoHeight.toPrecision(2);
            if (currentHeight == minVideoHeightPrecise) {
              this.videoHeight = minVideoHeight;
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(from: 1);
              }
            } else if (currentHeight < minVideoHeightPrecise) {
              // expand
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(
                  from: currentHeight / minVideoHeight,
                );
              }
              this.videoHeight = minVideoHeight;
            } else {
              // collapse
              if (_needAnimOnDimensionChanged(isVertical)) {
                isCollapsing = true;
                animationController.forward(
                  from: scrollCtr.offset / (maxVideoHeight - minVideoHeight),
                );
              }
              this.videoHeight = minVideoHeight;
            }
          }
        }
      } else {
        if (scrollCtr.offset != 0) {
          isExpanding = true;
          animationController.forward(from: 1 - scrollCtr.offset / videoHeight);
        }
      }
    } catch (_) {}
  }

  final isLoginVideo = Accounts.get(AccountType.video).isLogin;

  late final watchProgress = GStorage.watchProgress;
  void cacheLocalProgress() {
    if (!shouldPersistLocalPlaybackProgress(
      localDiagnostic: isLocalVideoDiagnostic,
    )) {
      return;
    }
    if (plPlayerController.playerStatus.isCompleted) {
      watchProgress.put(cid.value.toString(), entry.totalTimeMilli);
    } else if (playedTime case final playedTime?) {
      watchProgress.put(cid.value.toString(), playedTime.inMilliseconds);
    }
  }

  void initFileSource(BiliDownloadEntryInfo entry, {bool isInit = true}) {
    this.entry = entry;
    firstVideo = VideoItem(
      quality: VideoQuality.fromCode(entry.preferedVideoQuality),
      width: entry.ep?.width ?? entry.pageData?.width ?? 1,
      height: entry.ep?.height ?? entry.pageData?.height ?? 1,
    );
    if (watchProgress.get(cid.value.toString()) case final int progress?) {
      if (progress >= entry.totalTimeMilli - 400) {
        defaultST = Duration.zero;
      } else {
        defaultST = Duration(milliseconds: progress);
      }
    } else {
      defaultST = Duration.zero;
    }
    data = PlayUrlModel(timeLength: entry.totalTimeMilli);
    _setVideoHeight();
  }

  @override
  void onInit() {
    super.onInit();
    plPlayerController
      ..onHdrDisplayChanged = _hdrDisplayChangedCallback
      ..onRouteOptionsInvalidated = _routeInvalidatedCallback
      ..onRouteOptionsChanged = _routeChangedCallback;
    args = Get.arguments;
    isLocalVideoDiagnostic = isLocalVideoDiagnosticArgs(args);
    videoType = args['videoType'] ?? VideoType.ugc;
    if (videoType == VideoType.pgc) {
      if (!isLoginVideo) {
        _actualVideoType = VideoType.ugc;
      }
    } else if (args['pgcApi'] == true) {
      _actualVideoType = VideoType.pgc;
    }

    bvid = args['bvid'] ?? '';
    aid = args['aid'] ?? 0;
    cid = RxInt(args['cid'] ?? 0);
    epId = args['epId'];
    seasonId = args['seasonId'];
    pgcType = args['pgcType'];
    heroTag = args['heroTag'];
    cover = RxString(args['cover'] ?? '');
    isVertical = RxBool(args['isVertical'] ?? false);

    sourceType = args['sourceType'] ?? SourceType.normal;
    isFileSource = sourceType == SourceType.file || isLocalVideoDiagnostic;
    isPlayAll = sourceType != SourceType.normal && !isFileSource;
    if (isLocalVideoDiagnostic) {
      // These are UI layout placeholders only. Source dimensions, duration,
      // codec, quality, and HDR metadata remain unknown until mpv reports them.
      firstVideo = VideoItem(
        quality: VideoQuality.high1080,
        width: 1,
        height: 1,
      );
      defaultST = null;
      data = PlayUrlModel();
    } else if (isFileSource) {
      initFileSource(args['entry']);
    } else if (isPlayAll) {
      watchLaterTitle = args['favTitle'];
      _mediaDesc = args['desc'];
      getMediaList();
    }

    tabCtr = TabController(
      length: 2,
      vsync: this,
      initialIndex: Pref.defaultShowComment ? 1 : 0,
    );
  }

  Future<void> _onHdrDisplayChanged(bool displayHdr) async {
    if (displayHdr || isFileSource) return;
    // 先判当前档再访问 data：非 HDR 播放与面板能力无关。
    final current = currentVideoQa.value;
    if (current == null || !_isHdrQuality(current.code)) return;
    // 首个面板回调可能早于首个 DASH 响应（请求前的 refresh 同步触发）：
    // 此时没有可降级的播放，交由响应后的冷启动准入处理。
    if (!_hasPlaybackData) return;
    final revision = _playbackDataRevision;
    // 先选轨、再提交状态（复审 4）：共用兜底选轨（非 HDR ∧ 准入 ∧ 同一
    // 8K 资格门）。127 是 8K 但非 HDR 编号——选不出可播轨时不得写入虚假的
    // 降档状态（否则 currentVideoQa 停在被拒的 8K，后续回调因当前档非 HDR
    // 直接返回，再无降级机会），也不得报「已切换」。
    final fallbackTrack = _pickFallbackSdrTrack();
    if (fallbackTrack == null) {
      _toast('当前显示器不支持 HDR，且没有可播放的 SDR 画质');
      return;
    }
    final newQuality = fallbackTrack.quality;
    plPlayerController.cacheVideoQa = newQuality.code;
    currentVideoQa.value = newQuality;
    try {
      // 「已切换到」只在 updatePlayer 的选源通过并完成初始化调用之后发出：
      // 选源被拒时返回 false，保留当前播放且不播报成功；true 不等于播放成功。
      if (!await updatePlayer()) return;
    } on Object catch (error) {
      // 本回调的 Future 由 L 丢弃：失败必须留痕而非静默吞掉，且不得再
      // 报「已切换」。
      debugPrint('HDR downgrade reopen failed: ${error.runtimeType}');
      return;
    }
    // 重开期间可能已被新响应/新回调/页面关闭取代：不得播报过期决策。
    if (isClosed ||
        revision != _playbackDataRevision ||
        currentVideoQa.value?.code != newQuality.code) {
      return;
    }
    _toast('当前显示器不支持 HDR，已切换到：${newQuality.desc}');
  }

  bool _isHdrQuality(int? code) =>
      code == VideoQuality.dolbyVision.code ||
      code == VideoQuality.hdr.code ||
      code == VideoQuality.hdrVivid.code;

  /// §1.7/X：「HDR 模式=关闭」是菜单灰禁与开源准入的第二个输入。同步读
  /// 用户偏好，不耦合规划器；与 R 的 HdrMode.off → require(sdr) 映射同源，
  /// 设置变化经 onRouteOptionsInvalidated 推高 videoQualityMenuRevision。
  bool get _hdrModeOff => Pref.hdrMode == HdrMode.off;

  List<VideoItem> _tracksForQuality(int quality) =>
      data.dash?.video
          ?.where((track) => track.quality.code == quality)
          .toList() ??
      const <VideoItem>[];

  List<FormatItem> get currentDashQualityFormats {
    return formatsForCurrentDash(
      formats: data.supportFormats ?? const <FormatItem>[],
      tracks: data.dash?.video ?? const <VideoItem>[],
    );
  }

  /// 菜单是被动的（§1.2/§1.3）：只消费面板能力与用户 HDR 偏好这两个同步
  /// 事实，不咨询规划器、不等待嗅探、不触发能力查询。路由不可行的档位
  /// 保持可点，点击时由开源前守卫拒绝并解释。
  VideoQualityEligibility qualityEligibility(int quality) {
    return videoQualityEligibility(
      quality: quality,
      tracks: _tracksForQuality(quality),
      displaySupportsHdr: plPlayerController.hdrDisplaySupportsHdr.value,
      hdrModeOff: _hdrModeOff,
      gateEightKWithHardware: PlatformFeatureSupport.isMacOS,
      decodeCapabilities: _decodeCapabilities,
    );
  }

  Future<void> _probeEightKDecodeCapabilities(int revision) async {
    if (!PlatformFeatureSupport.isMacOS) return;
    final candidates =
        data.dash?.video
            ?.map(VideoDecodeCapability.fromTrack)
            .where((track) => track.isEightK)
            .fold<Map<String, VideoDecodeCapability>>(
              <String, VideoDecodeCapability>{},
              (all, track) => all..[track.key] = track,
            ) ??
        <String, VideoDecodeCapability>{};
    if (candidates.isEmpty) return;
    _decodeCapabilities
      ..clear()
      ..addAll(candidates);
    videoQualityMenuRevision.value++;
    final results = await Future.wait(
      candidates.values.map(probeMacosVideoDecode),
    );
    if (revision != _playbackDataRevision) return;
    for (final result in results) {
      _decodeCapabilities[result.key] = result;
    }
    videoQualityMenuRevision.value++;
  }

  /// 保留当前播放（§1.8）：开源前各道拒绝（轨存在性、面板/偏好、路由）
  /// 都不触碰 Player；进入真实 open 之后的失败按播放器既有错误契约处理。
  Future<bool> changeVideoQuality(int quality) async {
    if (_tracksForQuality(quality).isEmpty) {
      _toast('当前分 P 不提供该画质');
      return false;
    }
    // 面板能力与用户 HDR 偏好是同步事实，先于 probe 快速拒绝。
    final eligibility = qualityEligibility(quality);
    if (!eligibility.enabled) {
      _toast(eligibility.message);
      return false;
    }
    final revision = _playbackDataRevision;
    // Android 路由面的 probe 会恰好递增一次 serial；非 Android 路由面没有
    // probe，serial 不动，复核必须相应豁免，否则误杀全部非 Android 点击。
    final serial = plPlayerController.usesAndroidRouting
        ? _routingQuerySerial
        : null;
    final bool probed = await _probeRoutingCapabilities(revision);
    // 陈旧 probe：被更新 revision/serial 淘汰时不提示、不报成功。
    if (!probed ||
        revision != _playbackDataRevision ||
        (serial != null && serial + 1 != _routingQuerySerial)) {
      return false;
    }
    // 路由拒绝统一用 routeUnsupported 文案，与面板/偏好拒绝区分。
    if (!_openAdmitsQuality(quality)) {
      _toast(
        const VideoQualityEligibility(
          VideoQualityIneligibility.routeUnsupported,
        ).message,
      );
      return false;
    }
    final selected = findVideoByQa(
      quality,
      setCodecs: true,
      requireConfirmedEightKHardware: true,
    );
    if (selected == null) {
      _toast('当前画质资源不可用');
      return false;
    }
    final newQa = VideoQuality.fromCode(quality);
    plPlayerController.cacheVideoQa = newQa.code;
    currentVideoQa.value = newQa;
    // await 之后再返回 true：菜单的「画质已变为」随之落在真实开源之后。
    await updatePlayer();
    return true;
  }

  Future<void> getMediaList({
    bool isReverse = false,
    bool isLoadPrevious = false,
  }) async {
    final count = args['count'];
    if (!isReverse && count != null && mediaList.length >= count) {
      return;
    }
    final res = await UserHttp.getMediaList(
      type: args['mediaType'] ?? sourceType.mediaType,
      bizId: args['mediaId'] ?? -1,
      ps: 20,
      direction: isLoadPrevious ? true : false,
      oid: isReverse
          ? null
          : mediaList.isEmpty
          ? args['isContinuePlaying'] == true
                ? args['oid']
                : null
          : isLoadPrevious
          ? mediaList.first.aid
          : mediaList.last.aid,
      otype: isReverse
          ? null
          : mediaList.isEmpty
          ? null
          : isLoadPrevious
          ? mediaList.first.type
          : mediaList.last.type,
      desc: _mediaDesc,
      sortField: args['sortField'] ?? 1,
      withCurrent: mediaList.isEmpty && args['isContinuePlaying'] == true
          ? true
          : false,
    );
    if (res case Success(:final response)) {
      if (response.mediaList.isNotEmpty) {
        if (isReverse) {
          mediaList.value = response.mediaList;
          for (final item in mediaList) {
            if (item.cid != null) {
              try {
                Get.find<UgcIntroController>(tag: heroTag)
                    .onChangeEpisode(item);
              } catch (_) {}
              break;
            }
          }
        } else if (isLoadPrevious) {
          mediaList.insertAll(0, response.mediaList);
        } else {
          mediaList.addAll(response.mediaList);
        }
      }
    } else {
      res.toast();
    }
  }

  void showMediaListPanel(BuildContext context) {
    if (mediaList.isNotEmpty) {
      Widget panel() => MediaListPanel(
        mediaList: mediaList,
        onChangeEpisode: (episode) {
          try {
            Get.find<UgcIntroController>(tag: heroTag).onChangeEpisode(episode);
          } catch (_) {}
        },
        panelTitle: watchLaterTitle,
        bvid: bvid,
        count: args['count'],
        loadMoreMedia: getMediaList,
        desc: _mediaDesc,
        onReverse: () {
          _mediaDesc = !_mediaDesc;
          getMediaList(isReverse: true);
        },
        loadPrevious: args['isContinuePlaying'] == true
            ? () => getMediaList(isLoadPrevious: true)
            : null,
        onDelete:
            sourceType == SourceType.watchLater ||
                (sourceType == SourceType.fav && args['isOwner'] == true)
            ? (item, index) async {
                if (sourceType == SourceType.watchLater) {
                  final res = await UserHttp.toViewDel(
                    aids: item.aid.toString(),
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                  }
                } else {
                  final res = await FavHttp.favVideo(
                    resources: '${item.aid}:${item.type}',
                    delIds: '${args['mediaId']}',
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                    SmartDialog.showToast('取消收藏');
                  } else {
                    res.toast();
                  }
                }
              }
            : null,
      );
      if (plPlayerController.isFullScreen.value || showVideoSheet) {
        PageUtils.showVideoBottomSheet(
          context,
          child: plPlayerController.darkVideoPage
              ? Theme(data: ThemeUtils.darkTheme, child: panel())
              : panel(),
        );
      } else {
        childKey.currentState?.showBottomSheet(
          constraints: const BoxConstraints(),
          (context) => panel(),
        );
      }
    } else {
      getMediaList();
    }
  }

  bool isPortrait = true;

  bool get horizontalScreen => plPlayerController.horizontalScreen;

  bool get showVideoSheet =>
      (!horizontalScreen && !isPortrait) || plPlayerController.isDesktopPip;

  @override
  late final RxString videoLabel = ''.obs;
  @override
  int? get timeLength => data.timeLength;
  @override
  BlockConfigMixin get blockConfig => plPlayerController;
  @override
  Player? get player => plPlayerController.videoPlayerController;
  @override
  bool get isFullScreen => plPlayerController.isFullScreen.value;
  @override
  bool get autoPlay => _autoPlay.value;
  set autoPlay(bool value) => _autoPlay.value = value;
  @override
  bool get preInitPlayer => plPlayerController.preInitPlayer;
  @override
  int get currPosInMilliseconds =>
      defaultST?.inMilliseconds ?? plPlayerController.positionInMilliseconds;
  @override
  Future<void> seekTo(Duration duration, {required bool isSeek}) =>
      plPlayerController.seekTo(duration, isSeek: isSeek);

  @override
  Widget buildItem(Object item, Animation<double> animation) {
    final theme = ThemeUtils.theme;
    return Align(
      alignment: Alignment.centerLeft,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(begin: const Offset(-1.0, 0.0), end: Offset.zero),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: GestureDetector(
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (details.delta.dx < 0) {
                onRemoveItem(listData.indexOf(item), item);
              }
            },
            child: SearchText(
              bgColor: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.8,
              ),
              textColor: theme.colorScheme.onSecondaryContainer,
              padding: const .symmetric(horizontal: 8, vertical: 4),
              fontSize: 14,
              text: item is SegmentModel
                  ? '跳过: ${item.segmentType.shortTitle}'
                  : '上次看到第${(item as int) + 1}P，点击跳转',
              onTap: (_) {
                if (item is int) {
                  try {
                    UgcIntroController ugcIntroController =
                        Get.find<UgcIntroController>(tag: heroTag);
                    Part part =
                        ugcIntroController.videoDetail.value.pages![item];
                    ugcIntroController.onChangeEpisode(part);
                    SmartDialog.showToast('已跳至第${item + 1}P');
                  } catch (e) {
                    if (kDebugMode) debugPrint('$e');
                    SmartDialog.showToast('跳转失败');
                  }
                  onRemoveItem(listData.indexOf(item), item);
                } else if (item is SegmentModel) {
                  onSkip(item, isSeek: false);
                  onRemoveItem(listData.indexOf(item), item);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  ({int mode, int fontSize, Color color})? dmConfig;
  String? savedDanmaku;

  /// 发送弹幕
  Future<void> showShootDanmakuSheet() async {
    if (plPlayerController.dmState.contains(cid.value)) {
      SmartDialog.showToast('UP主已关闭弹幕');
      return;
    }
    final isPlaying =
        _autoPlay.value && plPlayerController.playerStatus.isPlaying;
    if (isPlaying) {
      await plPlayerController.pause();
    }
    await Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          final child = SendDanmakuPanel(
            cid: cid.value,
            bvid: bvid,
            progress: plPlayerController.positionInMilliseconds,
            initialValue: savedDanmaku,
            onSave: (danmaku) => savedDanmaku = danmaku,
            onSuccess: (danmakuModel) {
              savedDanmaku = null;
              plPlayerController.danmakuController?.addDanmaku(danmakuModel);
            },
            dmConfig: dmConfig,
            onSaveDmConfig: (dmConfig) => this.dmConfig = dmConfig,
          );
          if (plPlayerController.darkVideoPage) {
            return Theme(data: ThemeUtils.darkTheme, child: child);
          }
          return child;
        },
      ),
    );
    if (isPlaying) {
      plPlayerController.play();
    }
  }

  VideoItem? findVideoByQa(
    int qa, {
    bool setCodecs = false,
    bool requireConfirmedEightKHardware = false,
  }) {
    /// 根据currentVideoQa和currentDecodeFormats 重新设置videoUrl
    /// 选源收敛点（R2）：结果交由 playerInit 边界做最终准入（B3）。
    var videoList = data.dash!.video!
        .where((i) => i.id == qa)
        .where(_openAdmits)
        .toList();
    if (requireConfirmedEightKHardware) {
      videoList = tracksEligibleForPlayback(
        tracks: videoList,
        gateEightKWithHardware: PlatformFeatureSupport.isMacOS,
        decodeCapabilities: _decodeCapabilities,
      );
    }
    if (videoList.isEmpty) return null;

    final currentCodes = currentDecodeFormats.codes;
    VideoItem? bestVideo;
    int bestIndex = preferCodecs.length;
    for (final video in videoList) {
      final c = video.codecs ?? '';
      if (currentCodes.any(c.startsWith)) {
        return video;
      }
      for (int i = 0; i < bestIndex; i++) {
        if (preferCodecs[i].codes.any(c.startsWith)) {
          bestIndex = i;
          bestVideo = video;
          break;
        }
      }
    }

    if (setCodecs) {
      if (bestIndex < preferCodecs.length) {
        currentDecodeFormats = preferCodecs[bestIndex];
      } else {
        currentDecodeFormats = VideoDecodeFormatType.fromString(
          videoList.first.codecs!,
        );
      }
    }

    return bestVideo ?? videoList.first;
  }

  /// 更新画质、音质。返回选源是否通过并完成了初始化调用：选源被拒（如 8K
  /// 门拒）返回 false 且保留当前播放——降级路径（D/E1/E2）以此区分「已切换」
  /// 与「未切换」。true 不是打开/播放成功的收据：playerInit 内部仍有早退路径，
  /// 且 open 失败会落为 error 状态后正常返回。既有 `await updatePlayer();`
  /// 调用点忽略返回值亦兼容。
  Future<bool> updatePlayer() async {
    final currentVideoQa = this.currentVideoQa.value;
    if (currentVideoQa == null) return false;
    _autoPlay.value = true;
    playedTime = plPlayerController.videoPlayerController?.state.position;
    plPlayerController
      ..isBuffering.value = false
      ..buffered.value = 0;

    final selected = findVideoByQa(
      currentVideoQa.code,
      setCodecs: true,
      requireConfirmedEightKHardware: true,
    );
    if (selected == null) {
      _toast('当前画质资源不可用');
      return false;
    }
    firstVideo = selected;
    videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);
    debugPrint(
      'DV003_SEL quality=${currentVideoQa.code} '
      'host=${Uri.parse(videoUrl ?? '').host}',
    );

    /// 根据currentAudioQa 重新设置audioUrl
    if (currentAudioQa != null) {
      final firstAudio = data.dash!.audio!.firstWhere(
        (i) => i.id == currentAudioQa!.code,
        orElse: () => data.dash!.audio!.first,
      );
      audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
    }

    await playerInit();
    return true;
  }

  Future<void>? _initPlayerIfNeeded(bool autoFullScreenFlag) {
    if (_autoPlay.value ||
        (plPlayerController.preInitPlayer && !plPlayerController.processing) &&
            (isFileSource
                ? true
                : videoPlayerKey.currentState?.mounted == true)) {
      return playerInit(
        autoFullScreenFlag: autoFullScreenFlag && _autoPlay.value,
      );
    }
    return null;
  }

  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
  }) async {
    Duration? seek = defaultST ?? playedTime;
    if (seek == .zero) seek = null;
    seek ??= getFirstSegment();
    // 最终网络 rendition 准入（R2/B3）：playerInit 是所有 network open 的
    // 提交边界（页面恢复、首次手动播放、音质/codec 变更、播放地址编辑等
    // 入口都经此），firstVideo 不满足准入时在这里降档或拒绝。文件源与本地
    // 诊断源没有 DASH rendition，显式例外（editPlayUrl 的手动地址也经此
    // 入口、受同一 rendition 准入约束，地址本身不在此校验）。
    if (!isFileSource && !isLocalVideoDiagnostic && !_openAdmits(firstVideo)) {
      final requestedCode =
          currentVideoQa.value?.code ?? firstVideo.quality.code;
      var admitted = findVideoByQa(
        requestedCode,
        setCodecs: true,
        requireConfirmedEightKHardware: true,
      );
      // 复用冷启动/降级共用兜底选轨（复审 4 统一）：非 HDR ∧ 准入 ∧
      // 同一 8K 资格门（macOS 硬解确认，B3-d/e），具体 codec 由
      // findVideoByQa 统一选择/复核——不选回未授权 codec。
      admitted ??= _pickFallbackSdrTrack();
      if (admitted == null) {
        _toast('当前解码或 HDR 输出路径不支持该画质，已取消打开');
        return;
      }
      final newQuality = admitted.quality;
      plPlayerController.cacheVideoQa = newQuality.code;
      currentVideoQa.value = newQuality;
      firstVideo = admitted;
      videoUrl = VideoUtils.getCdnUrl(admitted.playUrls);
    }
    final request = plPlayerController.readRouteRequest();
    if (plPlayerController.usesAndroidRouting &&
        request.hasUnsupportedLegacyRequest) {
      await plPlayerController.stopForRouteOptions(request.unsupportedReason!);
      return;
    }
    final options =
        _routeSelection?.options ?? (_routeOptions ??= request.resolve());
    final configRevision = _routeOptionsRevision;
    final dataRevision = _playbackDataRevision;
    debugPrint(
      'DV003_OPEN quality=${firstVideo.quality.code} '
      'codec=${firstVideo.codecs} url=${Uri.parse(videoUrl!).host} '
      'videoUrl=$videoUrl',
    );
    await plPlayerController.setDataSource(
      isLocalVideoDiagnostic
          ? DirectFileSource(
              args['localVideoPath'] as String,
              routeOptions: options,
            )
          : isFileSource
          ? FileSource(
              dir: args['dirPath'],
              typeTag: entry.typeTag!,
              isMp4: entry.mediaType == 1,
              hasDashAudio: entry.hasDashAudio,
              routeOptions: options,
            )
          : NetworkSource(
              videoSource: videoUrl!,
              audioSource: audioUrl,
              videoSpec: DashRouteSelection.specification(firstVideo),
              outputTarget: _videoOutputTarget,
              routeOptions: options,
            ),
      seekTo: seek,
      duration: data.timeLength == null
          ? null
          : Duration(milliseconds: data.timeLength!),
      isVertical: isVertical.value,
      aid: isLocalVideoDiagnostic ? null : aid,
      bvid: isLocalVideoDiagnostic ? null : bvid,
      cid: isLocalVideoDiagnostic ? null : cid.value,
      autoplay: autoplay ?? _autoPlay.value,
      epid: isUgc ? null : epId,
      seasonId: isUgc ? null : seasonId,
      pgcType: isUgc ? null : pgcType,
      videoType: isLocalVideoDiagnostic ? null : videoType,
      onInit: () {
        videoState.value = true;
        setSubtitle(vttSubtitlesIndex.value);
      },
      width: firstVideo.width,
      height: firstVideo.height,
      volume: volume,
      initialVideoQuality: isLocalVideoDiagnostic
          ? null
          : firstVideo.quality.code,
      initialVideoCodec: isLocalVideoDiagnostic ? null : firstVideo.codecs,
      // DV005: the sniffed DOVI facts must reach the session hint, otherwise
      // a 126-tier open with a plain hvc1 codec string is unknown DV and the
      // planner blocks it (sourceMetadataUnknown).
      initialDoviFacts: _initialDoviFacts,
      autoFullScreenFlag: autoFullScreenFlag,
    );

    if (isClosed ||
        configRevision != _routeOptionsRevision ||
        dataRevision != _playbackDataRevision ||
        !identical(options, _routeOptions)) {
      return;
    }

    if (!isFileSource) {
      if (plPlayerController.enableBlock) {
        initSkip();
      }

      if (vttSubtitlesIndex.value == -1) {
        _queryPlayInfo();
      }

      if (plPlayerController.showDmChart && dmTrend.value == null) {
        _getDmTrend();
      }
    }

    defaultST = null;
  }

  bool isQuerying = false;

  final languages = Rxn<List<LanguageItem>>();
  final currLang = Rxn<String>();
  void setLanguage(String language) {
    if (currLang.value == language) return;
    if (!isLoginVideo) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    currLang.value = language;
    queryVideoUrl(fromReset: true);
  }

  Volume? volume;

  // 视频链接
  /// TODO: merge [DownloadHttp.getVideoUrl].
  Future<void> queryVideoUrl({
    bool fromReset = false,
    bool autoFullScreenFlag = false,
  }) async {
    if (isFileSource) {
      return _initPlayerIfNeeded(autoFullScreenFlag);
    }
    if (isQuerying) {
      return;
    }
    isQuerying = true;
    // Display capability is a cross-platform input to quality selection.
    // Each platform owns the channel implementation; the selection gate must
    // not depend on which platform happens to be running.
    await plPlayerController.refreshHdrDisplayCapabilities();
    if (plPlayerController.enableSponsorBlock && isBlock && !fromReset) {
      querySponsorBlock(bvid: bvid, cid: cid.value);
    }
    if (plPlayerController.cacheVideoQa == null) {
      final isWiFi = await ConnectivityUtils.isWiFi;
      plPlayerController
        ..cacheVideoQa = isWiFi
            ? Pref.defaultVideoQa
            : Pref.defaultVideoQaCellular
        ..cacheAudioQa = isWiFi
            ? Pref.defaultAudioQa
            : Pref.defaultAudioQaCellular;
      preferCodecs = isWiFi ? Pref.preferCodecs : Pref.preferCodecsCellular;
    }

    final hdrRequest =
        plPlayerController.hdrDisplaySupportsHdr.value &&
        plPlayerController.cacheVideoQa! >= VideoQuality.hdr.code;
    final result = await VideoHttp.videoUrl(
      cid: cid.value,
      bvid: bvid,
      // Request the user's HDR-capable quality preference from Bilibili.
      // Leaving qn unset hardcodes the API default (80), so the response can
      // omit DV/HDR tiers before the menu has a chance to select them.
      qn:
          plPlayerController.hdrDisplaySupportsHdr.value &&
              plPlayerController.cacheVideoQa! >= VideoQuality.hdr.code
          ? (plPlayerController.cacheVideoQa! == 127
                ? VideoQuality.dolbyVision.code
                : plPlayerController.cacheVideoQa)
          : null,
      epid: epId,
      seasonId: seasonId,
      // try_look responses are limited to ordinary qualities and can strip
      // DV/HDR even when qn requests an HDR tier. Ask for the real HDR stream
      // whenever the display and user preference permit it.
      tryLook: hdrRequest ? false : plPlayerController.tryLook,
      videoType: _actualVideoType ?? videoType,
      language: currLang.value,
      voiceBalance: plPlayerController.enableAudioNormalization,
    );

    if (result case Success(:final response)) {
      data = response;
      _playbackDataRevision++;
      _decodeCapabilities.clear();
      videoQualityMenuRevision.value++;
      // Do not let a saved 8K preference open a source while the matching
      // decoder result is still unknown. Waiting here is local/native only
      // and makes the initial source selection observe the same revision that
      // the menu shows; 4K and lower remain eligible regardless of the probe.
      final playbackRevision = _playbackDataRevision;
      if (!await _probeRoutingCapabilities(playbackRevision)) {
        isQuerying = false;
        return;
      }
      await _probeEightKDecodeCapabilities(playbackRevision);
      if (isClosed || playbackRevision != _playbackDataRevision) return;

      languages.value = data.language?.items;
      currLang.value = data.curLanguage;

      volume = data.volume;

      if (!fromReset) {
        final progress = args.remove('progress');
        if (progress != null) {
          defaultST = Duration(milliseconds: progress);
        } else {
          defaultST = Duration(milliseconds: data.lastPlayTime);
        }
      }

      if (!isUgc && !fromReset && plPlayerController.enablePgcSkip) {
        if (data.clipInfoList case final clipInfoList?) {
          resetBlock();
          handleSBData(clipInfoList);
        }
      }

      if (data.acceptDesc?.contains('试看') == true) {
        SmartDialog.showToast(
          '该视频为专属视频，仅提供试看',
          displayTime: const Duration(seconds: 3),
        );
      }
      if (data.dash == null) {
        if (data.durl case final durl?) {
          // it will cause all files to be opened simultaneously
          if (durl.length > 1) {
            // TODO: refa
            final sb = StringBuffer('edl://!no_chapters;');
            for (var i in durl) {
              final video = VideoUtils.getCdnUrl(i.playUrls);
              sb.write('%${video.length}%$video,length=${i.length! / 1000};');
            }
            videoUrl = sb.toString();
          } else {
            videoUrl = VideoUtils.getCdnUrl(durl.single.playUrls);
          }

          audioUrl = '';

          // 实际为FLV/MP4格式，但已被淘汰，这里仅做兜底处理
          final videoQuality = VideoQuality.fromCode(data.quality!);
          firstVideo = VideoItem(
            id: data.quality!,
            baseUrl: videoUrl,
            codecs: 'avc1',
            quality: videoQuality,
          );
          _setVideoHeight();
          currentDecodeFormats = VideoDecodeFormatType.AVC;
          currentVideoQa.value = videoQuality;
          await _initPlayerIfNeeded(autoFullScreenFlag);
          isQuerying = false;
          return;
        } else {
          SmartDialog.showToast('视频资源不存在');
          _autoPlay.value = false;
          videoState.value = false;
          if (plPlayerController.isFullScreen.value) {
            plPlayerController.triggerFullScreen(status: false);
          }
          isQuerying = false;
          return;
        }
      }

      await _selectInitialSource(autoFullScreenFlag: autoFullScreenFlag);
    } else {
      _autoPlay.value = false;
      videoState.value = false;
      if (plPlayerController.isFullScreen.value) {
        plPlayerController.triggerFullScreen(status: false);
      }
      result.toast();
    }
    isQuerying = false;
  }

  /// 冷启动实选（C 入口）：候选轨先经 [_openAdmits] 准入，缓存偏好被
  /// 拒绝时按质量值降到最高 SDR 档并提示一次；候选集为空则停播。
  /// 从 [queryVideoUrl] 提取仅为本切片可测（宿主打不到真实 playurl），
  /// 判定逻辑与原内联实现一一对应。
  Future<void> _selectInitialSource({required bool autoFullScreenFlag}) async {
    final List<VideoItem> videoList = data.dash!.video!
        .where(_openAdmits)
        .toList();
    if (videoList.isEmpty) {
      await plPlayerController.stopForRouteOptions('当前配置没有可用的解码及输出路径');
      SmartDialog.showToast('当前设备没有可用的解码及输出路径');
      isQuerying = false;
      return;
    }
    // if (kDebugMode) debugPrint("allVideosList:${allVideosList}");
    // 当前可播放的最高质量视频：显式取 admitted 轨中质量值最大者，
    // 不依赖服务器列表顺序（R4）。
    final curHighestVideoQa = videoList
        .map((item) => item.quality.code)
        .reduce((a, b) => a > b ? a : b);
    // 预设的画质为null，则当前可用的最高质量
    int targetVideoQa = curHighestVideoQa;
    var cacheVideoQa = plPlayerController.cacheVideoQa!;
    final requestedVideoQa = cacheVideoQa;
    // Display capability has been probed above, so this is a real negative
    // result rather than the controller's initial unknown=false state.
    // 用户关闭 HDR（§1.7/X）与面板无 HDR 同为拒绝输入。
    if ((!plPlayerController.hdrDisplaySupportsHdr.value || _hdrModeOff) &&
        _isHdrQuality(cacheVideoQa)) {
      final sdrVideos = videoList
          .where((item) => !_isHdrQuality(item.id))
          .toList();
      if (sdrVideos.isNotEmpty) {
        cacheVideoQa = sdrVideos
            .reduce((a, b) => a.quality.code > b.quality.code ? a : b)
            .quality
            .code;
        plPlayerController.cacheVideoQa = cacheVideoQa;
      }
    }
    if (cacheVideoQa <= curHighestVideoQa) {
      // 如果预设的画质低于当前最高
      targetVideoQa = videoList
          .map((item) => item.quality.code)
          .toSet()
          .toList()
          .findClosestTarget(
            (e) => e <= cacheVideoQa,
            (a, b) => a > b ? a : b,
          );
    }
    // Bilibili may report ordinary 4K (80) as the first/maximum entry in
    // accept_quality even when the DASH list also contains HDR tiers.  On
    // an HDR-capable display, a "highest" preference (127) must resolve to
    // the best available HDR tier instead of silently opening ordinary 4K.
    if (plPlayerController.hdrDisplaySupportsHdr.value &&
        cacheVideoQa >= VideoQuality.hdr.code) {
      final hdrVideos = videoList
          .where((item) => _isHdrQuality(item.quality.code))
          .where((item) => item.quality.code <= cacheVideoQa)
          .toList();
      if (hdrVideos.isNotEmpty) {
        targetVideoQa = hdrVideos
            .reduce((a, b) => a.quality.code > b.quality.code ? a : b)
            .quality
            .code;
      }
    }
    if ((!plPlayerController.hdrDisplaySupportsHdr.value || _hdrModeOff) &&
        _isHdrQuality(targetVideoQa)) {
      final sdrVideos = videoList
          .where((item) => !_isHdrQuality(item.id))
          .toList();
      if (sdrVideos.isNotEmpty) {
        targetVideoQa = sdrVideos
            .reduce((a, b) => a.quality.code > b.quality.code ? a : b)
            .quality
            .code;
        plPlayerController.cacheVideoQa = targetVideoQa;
      }
    }
    // A default 8K preference is only safe after a matching macOS hardware
    // decode probe. During probing (or on failure), start on the best
    // eligible non-8K rendition rather than a black AV1 output.
    if (!qualityEligibility(targetVideoQa).enabled) {
      final fallback = highestEligibleNonEightKTrack(
        tracks: videoList,
        displaySupportsHdr: plPlayerController.hdrDisplaySupportsHdr.value,
        hdrModeOff: _hdrModeOff,
        gateEightKWithHardware: PlatformFeatureSupport.isMacOS,
        decodeCapabilities: _decodeCapabilities,
      );
      if (fallback != null) {
        targetVideoQa = fallback.quality.code;
        plPlayerController.cacheVideoQa = targetVideoQa;
      }
    }
    // 真实降档提示条件（R4）：请求/缓存的 HDR 档以有效 rendition 形式存在
    // 于本片 DASH 且被准入拒绝；档不存在或无合格 codec 时不提示。
    final requestedOffered = data.dash!.video!.any(
      (item) =>
          item.id == requestedVideoQa &&
          DashRouteSelection.specification(item) != null,
    );
    final demotedFromHdr =
        _isHdrQuality(requestedVideoQa) &&
        targetVideoQa != requestedVideoQa &&
        requestedOffered;
    if (kDebugMode) {
      debugPrint(
        'Video quality selection: displayHdr='
        '${plPlayerController.hdrDisplaySupportsHdr.value}, '
        'cached=$cacheVideoQa, target=$targetVideoQa, '
        'available=${videoList.map((item) => item.quality.code).join(",")}',
      );
    }
    currentVideoQa.value = VideoQuality.fromCode(targetVideoQa);

    /// Select the initial URL through the same track transaction used by
    /// the menu. An 8K quality can expose AV1 and HEVC at once: a positive
    /// HEVC probe must not be followed by the legacy preference path
    /// selecting the unavailable AV1 rendition.
    final selectedVideo = findVideoByQa(
      targetVideoQa,
      setCodecs: true,
      requireConfirmedEightKHardware: true,
    );
    if (selectedVideo == null) {
      SmartDialog.showToast('当前画质资源不可用');
      isQuerying = false;
      return;
    }
    firstVideo = selectedVideo;
    _setVideoHeight();
    // 降档提示放在最终选源成功之后（R4）：选源失败不提示「已切换」。
    if (demotedFromHdr) {
      final target = VideoQuality.fromCode(targetVideoQa);
      _toast(
        _hdrModeOff
            ? '已关闭 HDR 输出，已切换到：${target.desc}'
            : '当前设备无法以 HDR 播放该档位，已切换到：${target.desc}',
      );
    }

    videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

    /// 优先顺序 设置中指定质量 -> 当前可选的最高质量
    AudioItem? firstAudio;
    final audioList = data.dash?.audio;
    if (audioList != null && audioList.isNotEmpty) {
      final List<int> audioIds = audioList.map((map) => map.id!).toList();
      int closestNumber = audioIds.findClosestTarget(
        (e) => e <= plPlayerController.cacheAudioQa,
        (a, b) => a > b ? a : b,
      );
      if (!audioIds.contains(plPlayerController.cacheAudioQa) &&
          audioIds.any((e) => e > plPlayerController.cacheAudioQa)) {
        closestNumber = AudioQuality.k192.code;
      }
      firstAudio = audioList.firstWhere(
        (e) => e.id == closestNumber,
        orElse: () => audioList.first,
      );
      audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
      if (firstAudio.id case final int id?) {
        currentAudioQa = AudioQuality.fromCode(id);
      }
    } else {
      audioUrl = '';
    }
    await _initPlayerIfNeeded(autoFullScreenFlag);
  }

  late final List<PostSegmentModel> postList = <PostSegmentModel>[];
  void onBlock(BuildContext context) {
    if (postList.isEmpty) {
      postList.add(
        PostSegmentModel(
          segment: Pair(
            first: 0,
            second: plPlayerController.positionInMilliseconds / 1000,
          ),
          category: SegmentType.sponsor,
          actionType: ActionType.skip,
        ),
      );
    }
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = PostPanel(
        enableSlide: false,
        videoDetailController: this,
        plPlayerController: plPlayerController,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => PostPanel(
          videoDetailController: this,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  RxList<Subtitle> subtitles = RxList<Subtitle>();
  final Map<int, ({bool isData, String id})> vttSubtitles = {};
  late final vttSubtitlesIndex = (-1).obs;
  late final showVP = true.obs;
  late final viewPointList = <ViewPointSegment>[].obs;

  // 设定字幕轨道
  Future<void> setSubtitle(int index) async {
    if (index <= 0) {
      await plPlayerController.videoPlayerController?.setSubtitleTrack(.no());
      vttSubtitlesIndex.value = index;
      return;
    }

    Future<void> setSub(({bool isData, String id}) subtitle) async {
      final sub = subtitles[index - 1];

      String subUri = subtitle.id;
      if (subtitle.isData) {
        subUri = 'memory://$subUri';
      }
      await plPlayerController.videoPlayerController?.setSubtitleTrack(
        SubtitleTrack(subUri, sub.lanDoc, sub.lan, uri: true),
      );
      vttSubtitlesIndex.value = index;
    }

    var subtitle = vttSubtitles[index - 1];
    if (subtitle == null) {
      final result = await VideoHttp.getSubtitles(
        subtitles[index - 1].subtitleUrl!,
      );
      if (!isClosed && result != null) {
        subtitle = (isData: true, id: result);
        vttSubtitles[index - 1] = subtitle;
      } else {
        return;
      }
    }
    await setSub(subtitle);
  }

  // interactive video
  int? graphVersion;
  EdgeInfoData? steinEdgeInfo;
  late final RxBool showSteinEdgeInfo = false.obs;

  Future<void> getSteinEdgeInfo([int? edgeId]) async {
    steinEdgeInfo = null;
    try {
      final res = await Request().get(
        '/x/stein/edgeinfo_v2',
        queryParameters: {
          'bvid': bvid,
          'graph_version': graphVersion,
          'edge_id': ?edgeId,
        },
      );
      if (res.data['code'] == 0) {
        steinEdgeInfo = EdgeInfoData.fromJson(res.data['data']);
      } else {
        if (kDebugMode) {
          debugPrint('getSteinEdgeInfo error: ${res.data['message']}');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('getSteinEdgeInfo: $e');
    }
  }

  late bool continuePlayingPart = Pref.continuePlayingPart;

  Future<void> _queryPlayInfo() async {
    vttSubtitles.clear();
    vttSubtitlesIndex.value = 0;
    if (plPlayerController.showViewPoints) {
      viewPointList.clear();
    }
    final res = await VideoHttp.playInfo(
      bvid: bvid,
      cid: cid.value,
      seasonId: seasonId,
      epId: epId,
    );
    if (res case Success(:final response)) {
      // interactive video
      late final introCtr = Get.find<UgcIntroController>(tag: heroTag);
      if (isUgc && graphVersion == null) {
        try {
          if (introCtr.videoDetail.value.rights?.isSteinGate == 1) {
            graphVersion = response.interaction?.graphVersion;
            getSteinEdgeInfo();
          }
        } catch (e) {
          if (kDebugMode) debugPrint('handle stein: $e');
        }
      }

      if (isUgc && continuePlayingPart) {
        continuePlayingPart = false;
        final lastCid = response.lastPlayCid;
        if (lastCid != null && lastCid != 0 && lastCid != cid.value) {
          try {
            final pages = introCtr.videoDetail.value.pages;
            if (pages != null && pages.length > 1) {
              final index = pages.indexWhere((item) => item.cid == lastCid);
              if (index != -1) {
                onAddItem(index);
              }
            }
          } catch (_) {}
        }
      }

      if (plPlayerController.showViewPoints &&
          response.viewPoints?.firstOrNull?.type == 2) {
        try {
          viewPointList.value = response.viewPoints!.map((item) {
            final end = (item.to! / (data.timeLength! / 1000)).clamp(0.0, 1.0);
            return ViewPointSegment(
              end: end,
              title: item.content,
              url: item.imgUrl,
              from: item.from,
              to: item.to,
            );
          }).toList();
        } catch (_) {}
      }

      if (response.subtitle?.subtitles case final sub? when (sub.isNotEmpty)) {
        _setSubtitle(sub);
      } else if (!Accounts.main.isLogin) {
        final res = await DmGrpc.dmView(aid, cid.value);
        if (res case Success(:final response)) {
          if (response.hasSubtitle() &&
              response.subtitle.subtitles.isNotEmpty) {
            _setSubtitle(
              response.subtitle.subtitles
                  .map(
                    (i) => Subtitle(
                      lan: i.lan,
                      lanDoc: i.lanDoc,
                      subtitleUrl: i.subtitleUrl.replaceFirst(
                        RegExp('^https?:'),
                        '',
                      ),
                      isAi: i.type == .AI,
                    ),
                  )
                  .toList()
                ..sort(),
            );
          }
        } else {
          res.toast();
        }
      }
    }
  }

  Future<void> _setSubtitle(List<Subtitle> sub) async {
    subtitles.value = sub;
    final idx = switch (Pref.subtitlePreferenceV2) {
      .off => 0,
      .on => 1,
      .withoutAi => sub.first.lan.startsWith('ai') ? 0 : 1,
      .auto =>
        !sub.first.lan.startsWith('ai') ||
                (PlatformUtils.isMobile &&
                    (await FlutterVolumeController.getVolume() ?? 0.0) <= 0.0)
            ? 1
            : 0,
    };
    await setSubtitle(idx);
  }

  void updateMediaListHistory(int aid) {
    if (args['sortField'] != null) {
      VideoHttp.medialistHistory(
        desc: _mediaDesc ? 1 : 0,
        oid: aid,
        upperMid: args['mediaId'],
      );
    }
  }

  void makeHeartBeat() {
    if (!isLocalVideoDiagnostic &&
        plPlayerController.enableHeart &&
        !plPlayerController.playerStatus.isCompleted &&
        playedTime != null) {
      try {
        plPlayerController.makeHeartBeat(
          data.timeLength != null
              ? (data.timeLength! - playedTime!.inMilliseconds).abs() <= 1000
                    ? -1
                    : playedTime!.inSeconds
              : playedTime!.inSeconds,
          type: HeartBeatType.completed,
          isManual: true,
          aid: aid,
          bvid: bvid,
          cid: cid.value,
          epid: isUgc ? null : epId,
          seasonId: isUgc ? null : seasonId,
          pgcType: isUgc ? null : pgcType,
          videoType: videoType,
        );
      } catch (_) {}
    }
  }

  void _unbindRoutingCallbacks() {
    ++_routingQuerySerial;
    if (identical(
      plPlayerController.onRouteOptionsInvalidated,
      _routeInvalidatedCallback,
    )) {
      plPlayerController.onRouteOptionsInvalidated = null;
    }
    if (identical(
      plPlayerController.onRouteOptionsChanged,
      _routeChangedCallback,
    )) {
      plPlayerController.onRouteOptionsChanged = null;
    }
    if (identical(
      plPlayerController.onHdrDisplayChanged,
      _hdrDisplayChangedCallback,
    )) {
      plPlayerController.onHdrDisplayChanged = null;
    }
  }

  @override
  void onClose() {
    _unbindRoutingCallbacks();
    cid.close();
    if (isFileSource && !isLocalVideoDiagnostic) {
      cacheLocalProgress();
    }
    introScrollCtr?.dispose();
    introScrollCtr = null;
    tabCtr.dispose();
    _scrollCtr?.dispose();
    animController
      ?..removeListener(_animListener)
      ..dispose();
    subtitles.clear();
    vttSubtitles.clear();
    super.onClose();
  }

  void onReset({bool isStein = false}) {
    if (isFileSource && !isLocalVideoDiagnostic) {
      cacheLocalProgress();
    }

    playedTime = null;
    defaultST = null;
    videoUrl = null;
    audioUrl = null;

    // danmaku
    savedDanmaku = null;

    // subtitle
    subtitles.clear();
    vttSubtitlesIndex.value = -1;
    vttSubtitles.clear();

    if (!isFileSource) {
      // language
      languages.value = null;
      currLang.value = null;

      // dm trend
      if (plPlayerController.showDmChart) {
        dmTrend.value = null;
      }

      // view point
      if (plPlayerController.showViewPoints) {
        viewPointList.clear();
      }

      // sponsor block
      if (blockConfig.enableBlock) {
        resetBlock();
      }

      // interactive video
      if (!isStein) {
        graphVersion = null;
      }
      steinEdgeInfo = null;
      showSteinEdgeInfo.value = false;
    }
  }

  late final Rx<LoadingState<List<double>>?> dmTrend =
      Rx<LoadingState<List<double>>?>(null);
  late final RxBool showDmTrendChart = true.obs;

  Future<void> _getDmTrend() async {
    dmTrend.value = LoadingState<List<double>>.loading();
    try {
      final res = await Request().get(
        'https://bvc.bilivideo.com/pbp/data',
        queryParameters: {
          'aid': aid,
          'bvid': bvid,
          'cid': cid.value,
          'r': 'loader',
        },
        options: Options(
          headers: {
            'user-agent': BrowserUa.pc,
            'origin': 'https://www.bilibili.com',
            'referer': 'https://www.bilibili.com/video/$bvid',
          },
        ),
      );
      dynamic json;
      try {
        json = (res.data['modules'] as List).first['params']['data'];
      } catch (_) {
        json = res.data;
      }
      final data = PbpData.fromJson(json);
      final stepSec = data.stepSec ?? 0;
      if (stepSec != 0 && data.events?.eDefault?.isNotEmpty == true) {
        dmTrend.value = Success(data.events!.eDefault!);
        return;
      }
      dmTrend.value = const Error(null);
    } catch (e) {
      dmTrend.value = const Error(null);
      if (kDebugMode) debugPrint('_getDmTrend: $e');
    }
  }

  void showNoteList(BuildContext context) {
    String? title;
    try {
      title = Get.find<UgcIntroController>(tag: heroTag)
          .videoDetail
          .value
          .title;
    } catch (_) {}
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = NoteListPage(
        oid: aid,
        enableSlide: false,
        heroTag: heroTag,
        isStein: graphVersion != null,
        title: title,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => NoteListPage(
          oid: aid,
          heroTag: heroTag,
          isStein: graphVersion != null,
          title: title,
        ),
      );
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  bool onSkipSegment() {
    try {
      if (plPlayerController.enableBlock) {
        if (listData.lastOrNull case final SegmentModel item) {
          onSkip(item, isSeek: false);
          onRemoveItem(listData.indexOf(item), item);
          return true;
        }
      }
    } catch (e, s) {
      Utils.reportError(e, s);
    }
    return false;
  }

  void toAudioPage() {
    int? id;
    int? extraId;
    PlaylistSource from = PlaylistSource.UP_ARCHIVE;
    if (isPlayAll) {
      id = args['mediaId'];
      extraId = sourceType.extraId;
      from = sourceType.playlistSource!;
    } else if (isUgc) {
      try {
        final ctr = Get.find<UgcIntroController>(tag: heroTag);
        id = ctr.videoDetail.value.ugcSeason?.id;
        if (id != null) {
          extraId = 8;
          from = PlaylistSource.MEDIA_LIST;
        }
      } catch (_) {}
    }
    AudioPage.toAudioPage(
      itemType: 1,
      id: id,
      oid: aid,
      subId: [cid.value],
      from: from,
      heroTag: _autoPlay.value ? heroTag : null,
      start: playedTime,
      audioUrl: audioUrl,
      extraId: extraId,
    );
  }

  Future<void> onDownload(BuildContext context) async {
    VideoDetailData? videoDetail;
    List<ugc.BaseEpisodeItem>? episodes;
    UgcIntroController? ugcIntroController;
    PgcInfoModel? pgcItem;
    if (isUgc) {
      try {
        ugcIntroController = Get.find<UgcIntroController>(tag: heroTag);
        videoDetail = ugcIntroController.videoDetail.value;
        if (videoDetail.ugcSeason?.sections case final sections?) {
          episodes = <ugc.BaseEpisodeItem>[];
          for (final i in sections) {
            if (i.episodes case final e?) {
              episodes.addAll(e);
            }
          }
        } else {
          episodes = videoDetail.pages;
        }
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download ugc: $e\n\n$s');
        }
      }
    } else {
      try {
        pgcItem = Get.find<PgcIntroController>(tag: heroTag).pgcItem;
        episodes = pgcItem.episodes;
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download pgc: $e\n\n$s');
        }
      }
    }
    if (episodes != null && episodes.isNotEmpty) {
      final downloadService = Get.find<DownloadService>();
      await downloadService.waitForInitialization;
      if (!context.mounted) {
        return;
      }
      final Set<int> cidSet = downloadService.downloadList
          .followedBy(downloadService.waitDownloadQueue)
          .map((e) => e.cid)
          .toSet();
      final index = episodes.indexWhere(
        (e) => e.cid == (seasonCid ?? cid.value),
      );

      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: min(640, context.mediaQueryShortestSide),
        ),
        builder: (context) {
          final maxChildSize =
              PlatformUtils.isMobile && !context.mediaQuerySize.isPortrait
              ? 1.0
              : 0.7;
          return DraggableScrollableSheet(
            snap: true,
            expand: false,
            minChildSize: 0,
            snapSizes: [maxChildSize],
            maxChildSize: maxChildSize,
            initialChildSize: maxChildSize,
            builder: (context, scrollController) => DownloadPanel(
              index: index,
              videoDetail: videoDetail,
              pgcItem: pgcItem,
              episodes: episodes!,
              scrollController: scrollController,
              videoDetailController: this,
              heroTag: heroTag,
              ugcIntroController: ugcIntroController,
              cidSet: cidSet,
            ),
          );
        },
      );
    }
  }

  void editPlayUrl() {
    String videoUrl = this.videoUrl ?? '';
    String audioUrl = this.audioUrl ?? '';
    Widget textField({
      required String label,
      required String initialValue,
      required ValueChanged<String> onChanged,
    }) => TextFormField(
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
      initialValue: initialValue,
      decoration: InputDecoration(
        label: Text(label),
        border: const OutlineInputBorder(),
      ),
    );
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        constraints: Style.dialogFixedConstraints,
        title: const Text('播放地址'),
        content: Column(
          spacing: 20,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            textField(
              label: 'Video Url',
              initialValue: videoUrl,
              onChanged: (value) => videoUrl = value,
            ),
            textField(
              label: 'Audio Url',
              initialValue: audioUrl,
              onChanged: (value) => audioUrl = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              this.videoUrl = videoUrl;
              this.audioUrl = audioUrl;
              playerInit();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onCast() async {
    SmartDialog.showLoading();
    final res = await VideoHttp.tvPlayUrl(
      cid: cid.value,
      objectId: epId ?? aid,
      playurlType: epId != null ? 2 : 1,
      qn: currentVideoQa.value?.code,
    );
    SmartDialog.dismiss();
    if (res case Success(:final response)) {
      final first = response.durl?.firstOrNull;
      if (first == null || first.playUrls.isEmpty) {
        SmartDialog.showToast('不支持投屏');
        return;
      }
      final url = VideoUtils.getCdnUrl(first.playUrls);

      String? title;
      try {
        if (isUgc) {
          title = Get.find<UgcIntroController>(tag: heroTag)
              .videoDetail
              .value
              .title;
        } else {
          title = Get.find<PgcIntroController>(tag: heroTag)
              .videoDetail
              .value
              .title;
        }
      } catch (_) {}
      if (kDebugMode) {
        debugPrint(title);
      }
      Get.toNamed('/dlna', parameters: {'url': url, 'title': ?title});
    } else {
      res.toast();
    }
  }
}
