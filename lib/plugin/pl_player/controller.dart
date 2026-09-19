import 'dart:async'
    show Completer, Future, StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show kMaxVolume;
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen_request_queue.dart';
import 'package:PiliPlus/plugin/pl_player/utils/player_touch_trace.dart';
import 'package:PiliPlus/plugin/pl_player/hdr_android.dart';
import 'package:PiliPlus/plugin/pl_player/hdr_platform.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart' show HapticFeedback, DeviceOrientation;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  final FullScreenOwnerToken _fullScreenOwner = claimFullScreenOwner();

  FullScreenOwnerToken get fullScreenOwner => _fullScreenOwner;

  bool get _allowDiagnosticDolbyVisionNative =>
      kDebugMode &&
      Platform.isMacOS &&
      Platform.environment['PILIPLUSX_FORCE_NATIVE_HDR'] == '1';

  final playerStatus = PlPlayerStatus(.playing);

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late Rect _lastWindowBounds;

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() {
    isDesktopPip = false;
    return Future.wait([
      if (showWindowTitleBar)
        windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(140, 140)),
      windowManager.setBounds(_lastWindowBounds),
      setAlwaysOnTop(false),
      windowManager.setAspectRatio(0),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    if (showWindowTitleBar) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }

    final Size size;
    final state = videoPlayerController!.state;
    int width = state.width ?? 0;
    int height = state.height ?? 0;
    if (width == 0) {
      width = this.width ?? 16;
    }
    if (height == 0) {
      height = this.height ?? 9;
    }
    if (height > width) {
      size = Size(140.0, 140.0 * height / width);
    } else {
      size = Size(140.0 * width / height, 140.0);
    }

    await windowManager.setMinimumSize(size);
    setAlwaysOnTop(true);
    windowManager
      ..setSize(size)
      ..setAspectRatio(width / height);
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      PiliAndroidHelper.disableAutoEnterPip();
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );
  late final fastForBackwardDuration_ = Duration(
    seconds: Pref.fastForBackwardDuration_,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool enableLandscapeAutoFullscreen =
      Pref.enableLandscapeAutoFullscreen;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;
  HdrCapabilities _hdrCapabilities = const HdrCapabilities(
    unsupportedReason: 'not-probed',
  );
  HdrSourceMetadata _hdrSource = const HdrSourceMetadata(
    kind: HdrSourceKind.unknown,
  );
  String? _hdrCodecHint;
  String? _hdrProbedCodec;
  int _hdrSourceGeneration = 0;
  HdrPlaybackDecision _hdrDecision = const HdrPlaybackDecision(
    output: HdrOutputMode.sdr,
    vo: 'gpu-next',
    hwdec: 'auto',
    surface: 'texture',
    reason: 'source-not-detected',
  );
  final hdrSurfaceGeneration = 0.obs;
  final hdrDisplaySupportsHdr = false.obs;
  final hdrOutputError = RxnString();
  StreamSubscription<Object?>? _hdrDisplaySubscription;
  void Function(bool displayHdr)? onHdrDisplayChanged;
  bool _hdrOutputRebuildInFlight = false;
  // Invalidates output rebuilds suspended across an await when the
  // player/page is disposed. This is separate from HDR source generation:
  // a source can remain current while its owner is gone.
  int _videoOutputTransactionGeneration = 0;
  int _hdrDisplayRefreshGeneration = 0;
  final _hdrOutputTransactionGate = HdrOutputTransactionGate();
  final _videoOutputPublicationGate = VideoOutputPublicationGate();
  // A shared media-kit Player accepts only one source open at a time.  The
  // gate makes an older dispatched open settle before its replacement begins,
  // otherwise completion order can leave the old media selected natively.
  final _playerSourceOperationGate = PlayerSourceOperationGate();
  // Keep the production source-open path on the same lifecycle coordinator
  // exercised by the opaque-handle timing tests. The controller continues to
  // own concrete media-kit handles and page state.
  late final _playerLifecycle =
      PlayerLifecycleOrchestrator<Player, VideoController>(
        openGate: _playerSourceOperationGate,
        outputPublicationGate: _videoOutputPublicationGate,
      );
  bool? _queuedHdrOutputRebuildHcpp;
  bool? _queuedHdrOutputRebuildSurfaceView;
  bool? _queuedHdrOutputRebuildNativeSurface;
  String? _lastHdrDiagnostic;
  String? _lastHdrVideoParamsDiagnostic;
  String? _lastHdrParameterReadback;
  String? _lastHdrNativeOutputAttempt;
  final _hdrNativeOutputAttemptGate = HdrNativeOutputAttemptGate();

  HdrCapabilities get hdrCapabilities => _hdrCapabilities;
  HdrSourceMetadata get hdrSource => _hdrSource;
  HdrPlaybackDecision get hdrDecision => _hdrDecision;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : subTitleStyle,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaler: TextScaler.noScaling,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(PlayCallback? playCallBack) {
    _playCallBack = playCallBack;
  }

  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus.value;
  }

  static Future<void> pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) async {
    if (_instance?.playerStatus.isPlaying ?? false) {
      await _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
  }

  static Future<void> seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) async {
    await _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  bool _initialOrientationHandled = false;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    if (!_isFullScreenTransactionAlive()) return;
    _orientation = param.orientation;
    if (!visible) return;
    if (!_initialOrientationHandled) {
      _initialOrientationHandled = true;
      if (enableLandscapeAutoFullscreen) {
        return;
      }
    }
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    debugPrint(
      '[FullscreenTrace] orientation=$orientation isFullScreen=$isFullScreen '
      'isManualFS=$isManualFS isVertical=$_isVertical '
      'horizontalScreen=$horizontalScreen auto=$enableLandscapeAutoFullscreen',
    );
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        // A manually entered OHOS fullscreen video must keep its landscape
        // orientation. The native orientation stream can emit a transient
        // portrait event while the phone is being held, which otherwise
        // exits the fullscreen layout and shrinks the native surface back to
        // its portrait buffer size.
        if (Platform.operatingSystem == 'ohos' &&
            isFullScreen &&
            !_isVertical &&
            isManualFS) {
          return;
        }
        if (!_isVertical &&
            isFullScreen &&
            (!horizontalScreen || enableLandscapeAutoFullscreen)) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode(owner: _fullScreenOwner);
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode(owner: _fullScreenOwner);
      case .landscapeLeft:
        if ((!horizontalScreen || enableLandscapeAutoFullscreen) &&
            !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode(owner: _fullScreenOwner);
        }
      case .landscapeRight:
        if ((!horizontalScreen || enableLandscapeAutoFullscreen) &&
            !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode(owner: _fullScreenOwner);
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        AndroidHelper$ToDart.onUserLeaveHint = Runnable.implement(
          $Runnable(run: _onUserLeaveHint),
        );
      } else {
        _isAutoEnterPip = true;
      }
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    final controller = _instance ??= PlPlayerController._();
    final firstPlayer = controller._playerCount == 0;
    controller
      ..isLive = isLive
      .._playerCount += 1;
    debugPrint(
      '[FullscreenPlatformTrace] get-controller owner=${controller._fullScreenOwner.generation} '
      'first=$firstPlayer playerCount=${controller._playerCount}',
    );
    if (firstPlayer) {
      controller._scheduleInitialFullScreenPlatformReconciliation();
    }
    return controller;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
    int? initialVideoQuality,
    String? initialVideoCodec,
  }) async {
    late final int sourceGeneration;
    try {
      sourceGeneration = ++_hdrSourceGeneration;
      _processing = true;
      _hdrCodecHint = initialVideoCodec;
      _hdrProbedCodec = null;
      _queuedHdrOutputRebuildHcpp = null;
      _queuedHdrOutputRebuildSurfaceView = null;
      // A source boundary needs a fresh native-output decision even when the
      // metadata tuple happens to match the preceding source.
      _lastHdrNativeOutputAttempt = null;
      hdrOutputError.value = null;
      _hdrSource = HdrSourceMetadata.fromBilibiliHints(
        quality: initialVideoQuality,
        codec: initialVideoCodec,
      );
      _hdrDecision = const HdrPlaybackDecision(
        output: HdrOutputMode.sdr,
        vo: 'gpu-next',
        hwdec: 'auto',
        surface: 'texture',
        reason: 'source-not-detected',
      );
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化视频倍速
      // _playbackSpeed.value = speed;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(
        dataSource,
        seekTo,
        volume,
        sourceGeneration: sourceGeneration,
      );

      // A reused Player may finish an older open after a replacement source
      // has started.  Do not publish its duration/status/init callback into
      // the replacement source's state.
      if (sourceGeneration != _hdrSourceGeneration) return;
      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      if (sourceGeneration != _hdrSourceGeneration) return;
      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      // An older queued native open may fail after a replacement source has
      // already entered loading. Its error is diagnostic only; publishing it
      // would turn the replacement page into DataStatus.error.
      if (sourceGeneration == _hdrSourceGeneration) {
        dataStatus.value = DataStatus.error;
        if (kDebugMode) {
          debugPrint(stackTrace.toString());
          debugPrint('plPlayer err:  $err');
        }
      }
    } finally {
      // An older open must not advertise the newer open as idle.
      if (sourceGeneration == _hdrSourceGeneration) {
        _processing = false;
      }
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  Future<Player> _initPlayer({required int sourceGeneration}) async {
    assert(_videoPlayerController == null);
    final opt = {
      'video-sync': Pref.videoSync,
      if (Pref.hdrMode == HdrMode.off) ...{
        'target-prim': 'bt.709',
        'target-trc': 'bt.1886',
      },
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
      'volume-max': kMaxVolume.toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    // A new source can start while the platform capability probe awaits.
    // Return the uncommitted local Player to its caller for disposal, but do
    // not let old codec/display facts overwrite the replacement source.
    final codecHint = _hdrCodecHint;
    final capabilities = await HdrPlatform.probe(codec: codecHint);
    if (sourceGeneration != _hdrSourceGeneration ||
        _playerCount == 0 ||
        _fsDisposed) {
      return player;
    }
    _hdrCapabilities = capabilities;
    hdrDisplaySupportsHdr.value = _hdrCapabilities.displayHdr;
    _hdrProbedCodec = codecHint;
    _hdrDecision = HdrDecision.choose(
      mode: Pref.hdrMode,
      source: _hdrSource,
      capabilities: _hdrCapabilities,
      hwdec: hwdec ?? 'auto',
      allowDolbyVisionNative: _allowDiagnosticDolbyVisionNative,
    );
    if (Platform.isAndroid && !_hdrDecision.useHcpp) {
      await HdrAndroid.setWindowHdrMode(hdr: false);
      if (sourceGeneration != _hdrSourceGeneration ||
          _playerCount == 0 ||
          _fsDisposed) {
        return player;
      }
    }
    debugPrint(
      'HDR capabilities: platform=${_hdrCapabilities.platform}, '
      'display=${_hdrCapabilities.displayHdr}, '
      'headroom=${_hdrCapabilities.headroom}, '
      'potentialHeadroom=${_hdrCapabilities.potentialHeadroom}, '
      'decoder=${_hdrCapabilities.decoderHdr}, '
      'vulkan=${_hdrCapabilities.vulkan}, '
      'hcpp=${_hdrCapabilities.canHcpp}, '
      'reason=${_hdrCapabilities.unsupportedReason}',
    );
    // The device capability alone must not force HCPP for SDR or an unknown
    // source. The decision also includes the source metadata and user mode.
    final useHcpp = _hdrDecision.useHcpp;

    // Keep output creation local until the source ownership is checked again.
    // A replacement can cross the capability-probe boundary while this native
    // surface is being created; publishing the old controller here would let
    // it survive after its local Player is returned for disposal below.
    late final VideoController nextVideoController;
    try {
      nextVideoController = await VideoController.create(
        player,
        configuration: _videoConfiguration(
          hcpp: useHcpp,
          nativeSurface: _hdrDecision.useNativeSurface,
        ),
      );
    } on Object catch (error) {
      // Do not let a failed stale create alter the replacement source's HDR
      // capability/decision state while choosing a fallback for itself.
      if (sourceGeneration != _hdrSourceGeneration ||
          _playerCount == 0 ||
          _fsDisposed) {
        return player;
      }
      if (!useHcpp) {
        _hdrCapabilities = _hdrCapabilities.copyWith(
          unsupportedReason: 'surface-init-failed:${error.runtimeType}',
        );
        nextVideoController = await VideoController.create(
          player,
          configuration: _videoConfiguration(hcpp: false, texture: true),
        );
      } else {
        _hdrCapabilities = _hdrCapabilities.copyWith(
          hcpp: false,
          unsupportedReason: 'hcpp-init-failed:${error.runtimeType}',
        );
        _refreshHdrDecision();
        if (kDebugMode) {
          debugPrint(
            'HCPP initialization failed; falling back to SurfaceView: $error',
          );
        }
        try {
          nextVideoController = await VideoController.create(
            player,
            configuration: _videoConfiguration(
              hcpp: false,
              surfaceView: true,
            ),
          );
        } catch (surfaceError) {
          if (sourceGeneration != _hdrSourceGeneration ||
              _playerCount == 0 ||
              _fsDisposed) {
            return player;
          }
          _hdrCapabilities = _hdrCapabilities.copyWith(
            unsupportedReason:
                'surface-init-failed:${surfaceError.runtimeType}',
          );
          nextVideoController = await VideoController.create(
            player,
            configuration: _videoConfiguration(hcpp: false, texture: true),
          );
        }
      }
    }

    if (sourceGeneration != _hdrSourceGeneration ||
        _playerCount == 0 ||
        _fsDisposed) {
      try {
        final platform = await nextVideoController.platform.future;
        await platform.disposeForRebuild();
      } catch (error) {
        debugPrint('stale initial video output dispose failed: $error');
      }
      return player;
    }
    _videoController = nextVideoController;
    _startListeners(player, sourceGeneration: sourceGeneration);
    if (Platform.isMacOS) {
      _hdrDisplaySubscription = HdrPlatform.displayChanges.listen(
        (_) => unawaited(refreshHdrDisplayCapabilities()),
        onError: (_) {},
      );
    }

    return player;
  }

  VideoControllerConfiguration _videoConfiguration({
    required bool hcpp,
    bool texture = false,
    bool surfaceView = false,
    bool nativeSurface = false,
  }) => VideoControllerConfiguration(
    vo: Platform.isAndroid
        ? hcpp
              ? 'gpu'
              : surfaceView
              ? 'mediacodec_embed'
              : null
        : null,
    enableHardwareAcceleration: hwdec != null,
    androidAttachSurfaceAfterVideoParameters: false,
    hwdec: hwdec,
    enableAndroidSurfaceProducer: !hcpp && !texture,
    usePlatformView: hcpp,
    // Keep ordinary OHOS SDR playback on the verified Flutter Texture path.
    // HCPP/native-surface is selected only when the HDR decision explicitly
    // requests that output topology.
    // OHOS native HDR keeps the XComponent as an independent compositor
    // layer even when the Android-specific HCPP capability is false.
    useHCPP: hcpp || (Platform.operatingSystem == 'ohos' && nativeSurface),
    useNativeSurface:
        !texture &&
        Pref.hdrMode == HdrMode.auto &&
        (nativeSurface ||
            Platform.isIOS ||
            Platform.isMacOS ||
            (Platform.operatingSystem == 'ohos' && hcpp)),
  );

  Future<void> _rebuildVideoOutput({
    required bool hcpp,
    bool surfaceView = false,
    bool nativeSurface = false,
  }) async {
    final player = _videoPlayerController;
    final old = _videoController;
    final sourceGeneration = _hdrSourceGeneration;
    if (player == null) return;
    final transactionGeneration = ++_videoOutputTransactionGeneration;
    if (kDebugMode && Platform.operatingSystem == 'ohos') {
      debugPrint(
        '[OhosOutputTrace] rebuild-start transaction=$transactionGeneration '
        'hcpp=$hcpp surfaceView=$surfaceView nativeSurface=$nativeSurface '
        'old=${old?.hashCode} sourceGeneration=$sourceGeneration '
        'hdrSurfaceGeneration=${hdrSurfaceGeneration.value}',
      );
    }
    bool isCurrent() =>
        !_fsDisposed &&
        sourceGeneration == _hdrSourceGeneration &&
        transactionGeneration == _videoOutputTransactionGeneration &&
        identical(player, _videoPlayerController);

    Future<void> disposeStaleOutput(VideoController controller) async {
      try {
        final platform = await controller.platform.future;
        await platform.disposeForRebuild();
      } catch (error) {
        debugPrint('stale video output dispose failed: $error');
      }
    }

    Future<bool> publishOutputIfCurrent(VideoController nextController) {
      return _videoOutputPublicationGate.publishOrDispose<VideoController>(
        candidate: nextController,
        isCurrent: isCurrent,
        // A fallback can finish after dispose or after a newer rebuild has
        // superseded this transaction. Never publish that controller into the
        // widget tree; it belongs to the stale transaction and must be
        // released through the same disposal barrier as the primary output.
        dispose: disposeStaleOutput,
        publish: (controller) {
          _videoController = controller;
          hdrOutputError.value = null;
          hdrSurfaceGeneration.value++;
        },
      );
    }

    final configureNativeColorSpace = hcpp && _hdrSource.hasNativeColorMetadata;
    if (old != null) {
      try {
        final platform = await old.platform.future;
        await platform.disposeForRebuild();
        // Disposal is an irreversible handoff. If this transaction lost the
        // source race while awaiting the platform, still detach this exact
        // controller when it is the one currently exposed; never leave a
        // released controller reachable through the widget tree. A newer
        // transaction that already published another controller is left
        // untouched by the identity check.
        if (identical(_videoController, old)) {
          _videoController = null;
          hdrSurfaceGeneration.value++;
        }
      } catch (error) {
        if (!isCurrent()) return;
        _hdrCapabilities = _hdrCapabilities.copyWith(
          unsupportedReason: 'output-dispose-failed:${error.runtimeType}',
        );
        _refreshHdrDecision();
        debugPrint('HDR output dispose failed: $error');
        rethrow;
      }
    }
    if (!isCurrent()) return;
    // The disposal barrier means [old] is no longer renderable. Remove it
    // from the widget tree before awaiting any platform transition so a frame
    // can never observe a disposed controller.
    _videoController = null;
    hdrOutputError.value = null;
    hdrSurfaceGeneration.value++;
    if (kDebugMode && Platform.operatingSystem == 'ohos') {
      debugPrint(
        '[OhosOutputTrace] rebuild-detached transaction=$transactionGeneration '
        'hdrSurfaceGeneration=${hdrSurfaceGeneration.value}',
      );
    }
    _lastHdrNativeOutputAttempt = null;
    if (Platform.isAndroid && !hcpp) {
      await HdrAndroid.setWindowHdrMode(hdr: false);
      if (!isCurrent()) return;
    }
    try {
      final nextController = await VideoController.create(
        player,
        configuration: _videoConfiguration(
          hcpp: hcpp,
          surfaceView: surfaceView,
          nativeSurface: nativeSurface,
        ),
      );
      if (!await publishOutputIfCurrent(nextController)) return;
      if (kDebugMode && Platform.operatingSystem == 'ohos') {
        debugPrint(
          '[OhosOutputTrace] rebuild-published transaction=$transactionGeneration '
          'controller=${nextController.hashCode} '
          'hdrSurfaceGeneration=${hdrSurfaceGeneration.value}',
        );
      }
      if (configureNativeColorSpace) {
        final applied = await _setHdrColorSpace(
          player,
          sourceGeneration: sourceGeneration,
        );
        if (!isCurrent()) return;
        if (!applied) {
          _hdrCapabilities = _hdrCapabilities.copyWith(
            nativeOutput: false,
            nativeOutputCapable: false,
            nativeOutputActive: false,
            hcpp: false,
            unsupportedReason: 'hdr-dataspace-after-rebuild-failed',
          );
          _refreshHdrDecision();
          _requestHdrOutputRebuild(hcpp: false, surfaceView: true);
          return;
        }
        _hdrCapabilities = _hdrCapabilities.copyWith(
          nativeOutput: true,
          nativeOutputCapable: true,
          nativeOutputActive: true,
          unsupportedReason: 'native-dataspace-applied',
        );
        _refreshHdrDecision();
        unawaited(
          _applyHdrOutputParameters(
            player,
            sourceGeneration: sourceGeneration,
          ),
        );
        debugPrint('HDR dataspace applied after output rebuild');
      }
    } catch (error) {
      if (!isCurrent()) return;
      Object failure = error;
      if (hcpp) {
        _hdrCapabilities = _hdrCapabilities.copyWith(
          hcpp: false,
          unsupportedReason: 'hcpp-rebuild-failed:${error.runtimeType}',
        );
        _refreshHdrDecision();
        try {
          final fallbackController = await VideoController.create(
            player,
            configuration: _videoConfiguration(
              hcpp: false,
              surfaceView: true,
            ),
          );
          if (!await publishOutputIfCurrent(fallbackController)) return;
          if (Platform.isAndroid) {
            await HdrAndroid.setWindowHdrMode(hdr: false);
            if (!isCurrent()) return;
          }
          debugPrint('HDR output fallback: HCPP -> SurfaceView');
          return;
        } catch (surfaceError) {
          failure = surfaceError;
          if (!isCurrent()) return;
        }
      }
      if (!isCurrent()) return;
      _hdrCapabilities = _hdrCapabilities.copyWith(
        unsupportedReason: 'surface-rebuild-failed:${failure.runtimeType}',
      );
      try {
        final fallbackController = await VideoController.create(
          player,
          configuration: _videoConfiguration(hcpp: false, texture: true),
        );
        if (!await publishOutputIfCurrent(fallbackController)) return;
        debugPrint('HDR output fallback: SurfaceView -> Texture');
        return;
      } catch (textureError) {
        failure = textureError;
      }
      if (!isCurrent()) return;
      _hdrCapabilities = _hdrCapabilities.copyWith(
        hcpp: false,
        unsupportedReason: 'output-rebuild-failed:${failure.runtimeType}',
      );
      _refreshHdrDecision();
      if (Platform.isAndroid) {
        await HdrAndroid.setWindowHdrMode(hdr: false);
        if (!isCurrent()) return;
      }
      hdrOutputError.value = 'video-output-rebuild-failed';
      debugPrint('HDR output rebuild failed: $failure');
    }
  }

  void _requestHdrOutputRebuild({
    required bool hcpp,
    bool surfaceView = false,
    bool? nativeSurface,
  }) {
    final requestedNativeSurface =
        nativeSurface ?? _hdrDecision.useNativeSurface;
    if (_hdrOutputRebuildInFlight) {
      _queuedHdrOutputRebuildHcpp = hcpp;
      _queuedHdrOutputRebuildSurfaceView = surfaceView;
      _queuedHdrOutputRebuildNativeSurface = requestedNativeSurface;
      return;
    }
    _hdrOutputRebuildInFlight = true;
    unawaited(
      _rebuildVideoOutput(
        hcpp: hcpp,
        surfaceView: surfaceView,
        nativeSurface: requestedNativeSurface,
      ).whenComplete(
        () {
          _hdrOutputRebuildInFlight = false;
          final queued = _queuedHdrOutputRebuildHcpp;
          final queuedSurfaceView = _queuedHdrOutputRebuildSurfaceView ?? false;
          final queuedNativeSurface =
              _queuedHdrOutputRebuildNativeSurface ?? false;
          _queuedHdrOutputRebuildHcpp = null;
          _queuedHdrOutputRebuildSurfaceView = null;
          _queuedHdrOutputRebuildNativeSurface = null;
          if (queued != null) {
            _requestHdrOutputRebuild(
              hcpp: queued,
              surfaceView: queuedSurfaceView,
              nativeSurface: queuedNativeSurface,
            );
          }
        },
      ),
    );
  }

  String _hdrOutputSignature(HdrPlaybackDecision decision) =>
      decision.outputTopologySignature;

  void _refreshHdrDecision() {
    _hdrDecision = HdrDecision.choose(
      mode: Pref.hdrMode,
      source: _hdrSource,
      capabilities: _hdrCapabilities,
      hwdec: hwdec ?? 'auto',
      allowDolbyVisionNative: _allowDiagnosticDolbyVisionNative,
    );
  }

  Future<void> _refreshHdrCapabilitiesForCodec(String codec) async {
    if (!Platform.isAndroid || codec == _hdrProbedCodec) return;
    final sourceGeneration = _hdrSourceGeneration;
    final player = _videoPlayerController;
    final previousDecision = _hdrDecision;
    final capabilities = await HdrPlatform.probe(codec: codec);
    if (sourceGeneration != _hdrSourceGeneration ||
        !identical(player, _videoPlayerController) ||
        _playerCount == 0 ||
        _fsDisposed) {
      return;
    }
    _hdrProbedCodec = codec;
    _hdrCapabilities = capabilities;
    _refreshHdrDecision();
    debugPrint(
      'HDR capabilities refreshed for codec=$codec: '
      'decoder=${capabilities.decoderHdr}, '
      'profiles=${capabilities.decoderProfiles.join(",")}, '
      'reason=${capabilities.unsupportedReason}',
    );
    if (_hdrOutputSignature(previousDecision) !=
            _hdrOutputSignature(_hdrDecision) &&
        _videoController != null) {
      _requestHdrOutputRebuild(hcpp: _hdrDecision.useHcpp);
    }
  }

  Future<void> refreshHdrDisplayCapabilities() async {
    final refreshGeneration = ++_hdrDisplayRefreshGeneration;
    final capabilities = await HdrPlatform.probe(codec: _hdrCodecHint);
    if (refreshGeneration != _hdrDisplayRefreshGeneration) return;
    final displayHdrFlagChanged =
        capabilities.displayHdr != _hdrCapabilities.displayHdr;
    final displayStateChanged = capabilities.displayStateChangedFrom(
      _hdrCapabilities,
    );
    if (!displayStateChanged) return;
    final player = _videoPlayerController;
    final hadNativeOutput = _hdrCapabilities.nativeOutputActive;
    _hdrCapabilities = _hdrCapabilities.copyWith(
      displayHdr: capabilities.displayHdr,
      headroom: capabilities.headroom,
      potentialHeadroom: capabilities.potentialHeadroom,
      nativeOutput: false,
      nativeOutputCapable: false,
      nativeOutputActive: false,
    );
    hdrDisplaySupportsHdr.value = capabilities.displayHdr;
    if (displayHdrFlagChanged) {
      _lastHdrNativeOutputAttempt = null;

      onHdrDisplayChanged?.call(capabilities.displayHdr);
    }
    _refreshHdrDecision();
    if (player == null) return;
    if (hadNativeOutput) {
      try {
        final platform = await _videoController?.platform.future;
        if (refreshGeneration != _hdrDisplayRefreshGeneration) return;
        if (platform != null) {
          await (platform as dynamic).resetHdrOutput();
          if (refreshGeneration != _hdrDisplayRefreshGeneration) return;
        }
      } catch (error) {
        debugPrint('HDR display-change reset failed: $error');
      }
    }
    await _applyHdrOutputParameters(player);
    if (refreshGeneration != _hdrDisplayRefreshGeneration ||
        _hdrSource.kind == HdrSourceKind.dolbyVision ||
        _hdrSource.kind == HdrSourceKind.hdrVivid ||
        _hdrSource.kind == HdrSourceKind.hdr10Plus ||
        !_hdrSource.hasNativeColorMetadata ||
        Pref.hdrMode != HdrMode.auto) {
      return;
    }
    final applied = await _setHdrColorSpace(
      player,
      sourceGeneration: _hdrSourceGeneration,
    );
    if (refreshGeneration != _hdrDisplayRefreshGeneration || !applied) return;
    _hdrCapabilities = _hdrCapabilities.copyWith(
      nativeOutput: true,
      nativeOutputCapable: true,
      nativeOutputActive: true,
      decoderHdr: true,
      unsupportedReason: 'native-dataspace-applied',
    );
    _refreshHdrDecision();
    await _applyHdrOutputParameters(player);
  }

  Future<bool> _setHdrColorSpace(
    Player player, {
    int? sourceGeneration,
  }) {
    final generation = sourceGeneration ?? _hdrSourceGeneration;
    final surfaceGeneration = hdrSurfaceGeneration.value;
    final transaction = _hdrOutputTransactionGate.run<bool>(
      isCurrent: () =>
          generation == _hdrSourceGeneration &&
          identical(player, _videoPlayerController) &&
          surfaceGeneration == hdrSurfaceGeneration.value,
      action: () => _setHdrColorSpaceSerial(
        player,
        sourceGeneration: generation,
        surfaceGeneration: surfaceGeneration,
      ),
    );
    return transaction.then((applied) => applied == true);
  }

  Future<bool> _setHdrColorSpaceSerial(
    Player player, {
    required int sourceGeneration,
    required int surfaceGeneration,
  }) async {
    final generation = sourceGeneration;
    bool isCurrent() =>
        generation == _hdrSourceGeneration &&
        identical(player, _videoPlayerController) &&
        surfaceGeneration == hdrSurfaceGeneration.value;
    final source = _hdrSource;
    if (!(Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS ||
            Platform.operatingSystem == 'ohos') ||
        !source.hasNativeColorMetadata ||
        !isCurrent()) {
      return false;
    }
    if (Platform.isAndroid) {
      if (!await HdrAndroid.setWindowHdrMode(hdr: true)) {
        return false;
      }
      if (!isCurrent()) return false;
      final handle = await player.handle;
      if (!isCurrent()) return false;
      final applied = await HdrAndroid.setColorSpace(
        handle: handle,
        transfer: source.transfer,
      );
      if (!applied) return false;
      if (!isCurrent()) return false;
    }
    final handle = await player.handle;
    if (!isCurrent()) return false;
    // Newer media-kit revisions own the native-output lifecycle. Keep a
    // dynamic compatibility bridge so older locked revisions still use the
    // legacy channel path while the public API branch can verify the actual
    // surface and renderer configuration.
    final videoController = _videoController;
    if (videoController != null) {
      try {
        final platform = await videoController.platform.future;
        if (!isCurrent()) return false;
        final dynamic nativePlatform = platform;
        final int? ohosSurfaceId = Platform.operatingSystem == 'ohos'
            ? (nativePlatform.wid.value as int?)
            : null;
        final surfaceHandle = ohosSurfaceId ?? handle;
        final created = await nativePlatform.createNativeOutput(
          surfaceId: surfaceHandle.toString(),
          windowHandle: surfaceHandle,
        );
        if (!isCurrent()) return false;
        final createdCapable =
            created == true || (created is Map && created['capable'] == true);
        if (!createdCapable) return false;
        var configured = await nativePlatform.configureHdrOutput(
          HdrOutputConfiguration(
            transfer: source.transfer,
            primaries: source.primaries,
            matrix: source.matrix,
            dolbyVisionProfile: source.dolbyVisionProfile,
            rpuPresent: source.rpuPresent,
            baseLayerPresent: source.baseLayerPresent,
            enhancementLayerPresent: source.enhancementLayerPresent,
            dvEnhancement: source.dvEnhancement,
            dynamicMetadataPresent: source.dynamicMetadataPresent,
            masteringMetadata: source.masteringMetadata,
            surfaceId: surfaceHandle.toString(),
            surfaceGeneration: surfaceGeneration,
          ).toMap(),
        );
        if (!isCurrent()) return false;
        if (Platform.operatingSystem == 'ohos' &&
            (configured is! Map || configured['active'] != true)) {
          // The XComponent surface is asynchronous. The OHOS backend keeps
          // this configuration pending and applies it from nativeSurfaceReady;
          // wait on its notifier instead of guessing with a fixed delay.
          final notifier = nativePlatform.nativeSurfaceActiveNotifier;
          final active = Completer<void>();
          void onActiveChanged() {
            if (notifier.value == true && !active.isCompleted) {
              active.complete();
            }
          }

          notifier.addListener(onActiveChanged);
          try {
            onActiveChanged();
            if (!active.isCompleted) {
              await Future.any<void>([
                active.future,
                Future<void>.delayed(const Duration(seconds: 3)),
              ]);
            }
          } finally {
            notifier.removeListener(onActiveChanged);
          }
          if (!isCurrent() || notifier.value != true) return false;
          configured = await nativePlatform.configureHdrOutput(
            HdrOutputConfiguration(
              transfer: source.transfer,
              primaries: source.primaries,
              matrix: source.matrix,
              dolbyVisionProfile: source.dolbyVisionProfile,
              rpuPresent: source.rpuPresent,
              baseLayerPresent: source.baseLayerPresent,
              enhancementLayerPresent: source.enhancementLayerPresent,
              dvEnhancement: source.dvEnhancement,
              dynamicMetadataPresent: source.dynamicMetadataPresent,
              masteringMetadata: source.masteringMetadata,
              surfaceId: surfaceHandle.toString(),
              surfaceGeneration: surfaceGeneration,
            ).toMap(),
          );
          if (!isCurrent()) return false;
        }
        // The Darwin layer can receive its first drawable/provider callback a
        // few frames after the controller is created. The media-kit Ready
        // callback configures the saved payload at that point, so retry the
        // same transaction once before declaring HDR unavailable.
        if ((Platform.isMacOS || Platform.isIOS) &&
            (configured is! Map || configured['active'] != true)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (!isCurrent()) return false;
          configured = await nativePlatform.configureHdrOutput(
            HdrOutputConfiguration(
              transfer: source.transfer,
              primaries: source.primaries,
              matrix: source.matrix,
              dolbyVisionProfile: source.dolbyVisionProfile,
              rpuPresent: source.rpuPresent,
              baseLayerPresent: source.baseLayerPresent,
              enhancementLayerPresent: source.enhancementLayerPresent,
              dvEnhancement: source.dvEnhancement,
              dynamicMetadataPresent: source.dynamicMetadataPresent,
              masteringMetadata: source.masteringMetadata,
              surfaceId: surfaceHandle.toString(),
              surfaceGeneration: surfaceGeneration,
            ).toMap(),
          );
          if (!isCurrent()) return false;
        }
        if (configured is! Map || configured['active'] != true) return false;
        if (Platform.isMacOS ||
            Platform.isIOS ||
            Platform.operatingSystem == 'ohos') {
          // The media-kit native surface is authoritative on Darwin. The app
          // channel still reports false because it only probes the Flutter
          // window, not the native surface that owns HDR output.
          return true;
        }
      } on NoSuchMethodError {
        // The currently locked media-kit may predate the public lifecycle API.
      } catch (error) {
        debugPrint('media-kit native output configuration failed: $error');
        return false;
      }
    }
    final output = await HdrPlatform.configureOutput(
      HdrOutputConfiguration(
        transfer: source.transfer,
        primaries: source.primaries,
        matrix: source.matrix,
        dolbyVisionProfile: source.dolbyVisionProfile,
        rpuPresent: source.rpuPresent,
        baseLayerPresent: source.baseLayerPresent,
        enhancementLayerPresent: source.enhancementLayerPresent,
        dvEnhancement: source.dvEnhancement,
        dynamicMetadataPresent: source.dynamicMetadataPresent,
        masteringMetadata: source.masteringMetadata,
        surfaceId: handle.toString(),
        surfaceGeneration: surfaceGeneration,
      ),
    );
    if (!isCurrent()) return false;
    return output.active;
  }

  Future<void> _applyHdrOutputParameters(
    Player player, {
    int? sourceGeneration,
  }) {
    final generation = sourceGeneration ?? _hdrSourceGeneration;
    final surfaceGeneration = hdrSurfaceGeneration.value;
    final run = _hdrOutputTransactionGate.run<void>(
      isCurrent: () =>
          generation == _hdrSourceGeneration &&
          identical(player, _videoPlayerController) &&
          surfaceGeneration == hdrSurfaceGeneration.value,
      action: () => _applyHdrOutputParametersSerial(
        player,
        sourceGeneration: generation,
      ),
    );
    return run.then<void>((_) {});
  }

  Future<void> _applyHdrOutputParametersSerial(
    Player player, {
    int? sourceGeneration,
  }) async {
    final generation = sourceGeneration ?? _hdrSourceGeneration;
    final surfaceGeneration = hdrSurfaceGeneration.value;
    bool isCurrent() =>
        generation == _hdrSourceGeneration &&
        identical(player, _videoPlayerController) &&
        surfaceGeneration == hdrSurfaceGeneration.value;

    if (!isCurrent()) return;
    final native = _hdrDecision.output == HdrOutputMode.nativeHdr;
    final shouldResetNativeOutput =
        !native &&
        (_hdrCapabilities.nativeOutputActive ||
            Platform.operatingSystem == 'ohos');
    if (shouldResetNativeOutput) {
      try {
        final platform = await _videoController?.platform.future;
        if (!isCurrent()) return;
        if (platform != null) {
          await (platform as dynamic).resetHdrOutput();
          if (!isCurrent()) return;
        }
        _hdrCapabilities = _hdrCapabilities.copyWith(
          nativeOutput: false,
          nativeOutputActive: false,
          unsupportedReason: 'native-output-reset-for-sdr',
        );
      } catch (error) {
        debugPrint('HDR native output reset failed: $error');
      }
    }
    // OHOS owns the complete mpv HDR parameter transaction in its video
    // backend. Keep the app responsible for policy and configure/reset entry
    // points, but do not race the backend with a second property writer.
    if (Platform.operatingSystem == 'ohos') return;
    final transfer = switch (_hdrSource.transfer) {
      HdrTransfer.hlg => 'arib-std-b67',
      HdrTransfer.pq => 'pq',
      _ => 'bt.1886',
    };
    // The Darwin native surface consumes extended-linear BT.2020 samples.
    // Reapplying pq here would make the layer interpret PQ code values as
    // linear light, which visibly washes out Dolby Vision/HDR highlights.
    // The verified producer/display contract exists only for macOS. Do not
    // silently apply the macOS 400-nit mapping to iOS without an equivalent
    // native-surface and display-output measurement.
    final darwinNative = native && Platform.isMacOS;
    final values = <String, String>{
      'target-prim': native ? 'bt.2020' : 'bt.709',
      'target-trc': darwinNative ? 'linear' : (native ? transfer : 'bt.1886'),
      'target-colorspace-hint': native ? 'yes' : 'auto',
      // The Darwin native surface consumes display-referred linear BT.2020.
      // Keep mpv's tone-mapping stage enabled so a 1000-nit source is mapped
      // to the same 400-nit reference used by the verified brew-mpv setup
      // before it reaches the linear EDR buffer. This is producer mapping,
      // not a post-render gain. Non-Darwin native outputs retain their
      // platform-specific default.
      'tone-mapping': darwinNative ? 'bt.2390' : (native ? 'auto' : 'bt.2390'),
      // Always restore this property. The same Player can be reused across
      // HDR and SDR sources, and mpv properties survive a native-output reset.
      'target-peak': darwinNative ? '400' : 'auto',
    };
    // Local A/B only. These overrides are deliberately debug-only and are
    // never used as production defaults; they isolate whether the remaining
    // difference is caused by the producer transfer/peak contract.
    if (kDebugMode) {
      final diagnosticTargetTrc =
          Platform.environment['PILIPLUSX_HDR_TARGET_TRC'];
      final diagnosticToneMapping =
          Platform.environment['PILIPLUSX_HDR_TONE_MAPPING'];
      final diagnosticTargetPeak =
          Platform.environment['PILIPLUSX_HDR_TARGET_PEAK'];
      for (final entry in <String, String?>{
        'target-trc': diagnosticTargetTrc,
        'tone-mapping': diagnosticToneMapping,
        'target-peak': diagnosticTargetPeak,
      }.entries) {
        if (entry.value != null && entry.value!.isNotEmpty) {
          values[entry.key] = entry.value!;
          debugPrint('HDR diagnostic ${entry.key} override: ${entry.value}');
        }
      }
    }
    try {
      for (final entry in values.entries) {
        if (!isCurrent()) return;
        await player.setProperty(entry.key, entry.value);
        if (!isCurrent()) return;
      }
      if (kDebugMode) {
        final handle = await player.handle;
        if (!isCurrent()) return;
        final readback = <String, String>{};
        // Read the effective peak without writing it. The shipped Darwin
        // mpv has libplacebo disabled, so this is diagnostic evidence only;
        // do not guess or force a target peak from another mpv build.
        for (final property in <String>[...values.keys, 'target-peak']) {
          if (!isCurrent()) return;
          try {
            readback[property] = await player.getProperty(property);
          } catch (error) {
            readback[property] = '<unavailable:${error.runtimeType}>';
          }
          if (!isCurrent()) return;
        }
        final diagnostic =
            'HDR mpv parameter readback: generation=$generation, '
            'handle=$handle, requested=$values, actual=$readback';
        if (_lastHdrParameterReadback != diagnostic) {
          _lastHdrParameterReadback = diagnostic;
          debugPrint(diagnostic);
        }
      }
    } catch (error) {
      debugPrint('HDR output parameter update failed: $error');
    }
  }

  Future<void> _applyHdrOutputParametersIfCurrent(
    Player player,
    int sourceGeneration,
  ) async {
    if (sourceGeneration != _hdrSourceGeneration) return;
    await _applyHdrOutputParameters(player, sourceGeneration: sourceGeneration);
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume, {
    required int sourceGeneration,
  }) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer(sourceGeneration: sourceGeneration);
      // Two source changes can both cross _initPlayer before either assigns
      // the shared field.  Dispose the stale local Player rather than letting
      // it overwrite the replacement source's shared Player.
      if (sourceGeneration != _hdrSourceGeneration || _playerCount == 0) {
        player.dispose();
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    // Do not let an old source continue into Player.open after an async
    // player/shader initialization. The shared Player may already belong to
    // the replacement source at this point.
    if (sourceGeneration != _hdrSourceGeneration ||
        !identical(player, _videoPlayerController)) {
      return;
    }
    // Keep the current Player in an immutable local for the queued closure.
    final currentPlayer = player;

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    if (kDebugMode) {
      debugPrint(
        '[OhosPlaybackTrace] player.open initialize '
        'play=false seekTo=$seekTo source=${video.length > 120 ? '${video.substring(0, 120)}...' : video}',
      );
    }
    final opened = await _playerLifecycle.openCurrent(
      player: currentPlayer,
      isCurrent: () =>
          sourceGeneration == _hdrSourceGeneration &&
          _playerCount > 0 &&
          identical(currentPlayer, _videoPlayerController),
      open: (player) => player.open(
        Media(
          video,
          start: seekTo,
          httpHeaders: {
            'User-Agent': BrowserUa.pc,
            'Referer': HttpString.baseUrl,
          },
          extras: extras.isEmpty ? null : extras,
        ),
        play: false,
      ),
      rebindListeners: (player) {
        _removeListeners();
        _startListeners(player, sourceGeneration: sourceGeneration);
      },
    );

    // A source replacement or disposal can occur while the native open is in
    // flight. Its completion is intentionally not treated as this source's
    // successful open, and must not rebind listener ownership below.
    if (!opened) return;
  }

  Future<void>? refreshPlayer({String reason = 'unspecified'}) {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      if (kDebugMode) {
        debugPrint(
          '[OhosPlaybackTrace] refreshPlayer '
          'reason=$reason '
          'position=${ctr.state.position} playing=${ctr.state.playing} '
          'buffering=${ctr.state.buffering} source=${ctr.current.last.uri}',
        );
      }
      return ctr.open(
        ctr.current.last.copyWith(start: ctr.state.position),
        play: true,
      );
    }
    return null;
  }

  void retryVideoOutput() {
    if (_videoController == null) {
      hdrOutputError.value = null;
      _requestHdrOutputRebuild(hcpp: _hdrDecision.useHcpp);
      return;
    }
    if (kDebugMode) {
      debugPrint('[OhosPlaybackTrace] retryVideoOutput');
    }
    unawaited(
      refreshPlayer(reason: 'retry-video-output') ?? Future<void>.value(),
    );
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (isLive) {
      await setPlaybackSpeed(1.0);
    } else {
      if (_videoPlayerController?.state.rate != _playbackSpeed.value) {
        await setPlaybackSpeed(_playbackSpeed.value);
      }
    }
    _initVideoFit();
    // if (_looping) {
    //   await setLooping(_looping);
    // }

    // 跳转播放
    // if (seekTo != Duration.zero) {
    //   await this.seekTo(seekTo);
    // }

    // 自动播放
    if (_autoPlay) {
      playIfExists();
      // await play(duration: duration);
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  /// 播放事件监听
  void _startListeners(
    NativePlayer player, {
    required int sourceGeneration,
  }) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        PlayerTouchTrace.message(
          'player-state playing=$playing generation=$sourceGeneration '
          'position=${videoPlayerController?.state.position}',
        );
        WakelockPlus.toggle(enable: playing);
        if (playing) {
          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
          playerStatus.value = .playing;
        } else {
          _disableAutoEnterPip();
          playerStatus.value = .paused;
        }

        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          isBuffering.value,
          isLive,
        );

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus.value = .completed;

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (!isSeeking.value) {
            this.position.value = posInSeconds;
          }

          videoPlayerServiceHandler?.onPositionChange(position);

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen(updateDuration),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.tracks.listen((tracks) {
        if (sourceGeneration != _hdrSourceGeneration) return;
        // Track metadata carries the decoder's codec name, which is the
        // earliest reliable correction to the Bilibili quality/codec guess.
        for (final track in tracks.video) {
          final codec = track.codec;
          if (codec != null && codec.isNotEmpty) {
            _hdrCodecHint = codec;
            if (kDebugMode) {
              debugPrint(
                'Video track codec=$codec, id=${track.id}, title=${track.title}',
              );
            }
            if (Platform.isAndroid && codec != _hdrProbedCodec) {
              unawaited(_refreshHdrCapabilitiesForCodec(codec));
            }
            break;
          }
        }
      }),
      stream.videoParams.listen((params) {
        if (sourceGeneration != _hdrSourceGeneration) return;
        if (kDebugMode) {
          final diagnostic =
              'HDR videoParams: generation=$sourceGeneration, '
              'handle=${player.hashCode}, params=$params';
          if (_lastHdrVideoParamsDiagnostic != diagnostic) {
            _lastHdrVideoParamsDiagnostic = diagnostic;
            debugPrint(diagnostic);
          }
        }
        final previousDecision = _hdrDecision;
        final corrected = HdrSourceMetadata.fromMpvProperties({
          ...?(_hdrCodecHint == null ? null : {'codec': _hdrCodecHint!}),
          if (params.primaries != null) 'primaries': params.primaries!,
          if (params.gamma != null) 'transfer': params.gamma!,
          if (params.colormatrix != null) 'matrix': params.colormatrix!,
        });
        // Some native versions emit videoParams before color metadata is
        // available. Preserve the Bilibili quality hint until mpv provides a
        // real correction instead of briefly downgrading HDR to SDR.
        if (corrected.kind != HdrSourceKind.unknown ||
            corrected.transfer != HdrTransfer.unknown ||
            corrected.primaries != HdrPrimaries.unknown ||
            corrected.matrix != HdrMatrix.unknown) {
          _hdrSource = _hdrSource.mergeMpvCorrection(corrected);
        }
        _hdrDecision = HdrDecision.choose(
          mode: Pref.hdrMode,
          source: _hdrSource,
          capabilities: _hdrCapabilities,
          hwdec: hwdec ?? 'auto',
          allowDolbyVisionNative: _allowDiagnosticDolbyVisionNative,
        );
        final outputTopologyChanged =
            _hdrOutputSignature(previousDecision) !=
            _hdrOutputSignature(_hdrDecision);
        final darwinNativeCandidate =
            (Platform.isMacOS || Platform.isIOS) &&
            Pref.hdrMode == HdrMode.auto &&
            _videoController != null &&
            (_hdrSource.kind != HdrSourceKind.dolbyVision ||
                _allowDiagnosticDolbyVisionNative ||
                _hdrSource.supportsConvertedHdrOutput) &&
            _hdrSource.kind != HdrSourceKind.hdrVivid &&
            _hdrSource.kind != HdrSourceKind.hdr10Plus &&
            _hdrSource.hasNativeColorMetadata;
        // OHOS may expose an XComponent/native-window candidate, but a
        // display HDR probe and a surface ID alone are not proof of native
        // HDR output. Promotion still requires the backend's active report.
        final ohosNativeCandidate =
            Platform.operatingSystem == 'ohos' &&
            _videoController?.nativeSurfaceCandidate == true &&
            _videoController?.nativeSurfaceActive == true;
        if (outputTopologyChanged &&
            _videoController != null &&
            !darwinNativeCandidate) {
          if (kDebugMode && Platform.operatingSystem == 'ohos') {
            debugPrint(
              '[OhosOutputTrace] video-params topology-change '
              'previous=${previousDecision.outputTopologySignature} '
              'current=${_hdrDecision.outputTopologySignature} '
              'nativeCandidate=$ohosNativeCandidate',
            );
          }
          _requestHdrOutputRebuild(hcpp: _hdrDecision.useHcpp);
        }
        unawaited(
          _applyHdrOutputParametersIfCurrent(player, sourceGeneration),
        );
        final diagnostic =
            'HDR decision: source=${_hdrSource.kind.name}, '
            'primaries=${_hdrSource.primaries.name}, '
            'transfer=${_hdrSource.transfer.name}, '
            'matrix=${_hdrSource.matrix.name}, '
            'dvProfile=${_hdrSource.observed('dolbyVisionProfile') ? (_hdrSource.dolbyVisionProfile ?? 'none') : 'unknown'}, '
            'rpu=${_hdrSource.observed('rpuPresent') ? _hdrSource.rpuPresent : 'unknown'}, '
            'el=${_hdrSource.observed('enhancementLayerPresent') ? _hdrSource.enhancementLayerPresent : 'unknown'}, '
            'dvEnhancement=${_hdrSource.observed('dvEnhancement') ? _hdrSource.dvEnhancement.name : 'unknown'}, '
            'dynamicMetadata=${_hdrSource.observed('dynamicMetadataPresent') ? _hdrSource.dynamicMetadataPresent : 'unknown'}, '
            'output=${_hdrDecision.output.name}, '
            'surface=${_hdrDecision.surface}, '
            'vo=${_hdrDecision.vo}, hwdec=${_hdrDecision.hwdec}, '
            'reason=${_hdrDecision.reason}';
        if (_lastHdrDiagnostic != diagnostic) {
          _lastHdrDiagnostic = diagnostic;
          debugPrint(diagnostic);
        }
        final nativeOutputAttempt = [
          _hdrSource.kind.name,
          _hdrSource.transfer.name,
          _hdrSource.primaries.name,
          _hdrSource.matrix.name,
          hdrSurfaceGeneration.value,
        ].join(':');
        if ((_hdrCapabilities.canHcpp ||
                darwinNativeCandidate ||
                ohosNativeCandidate) &&
            _hdrSource.hasNativeColorMetadata &&
            (!outputTopologyChanged || darwinNativeCandidate) &&
            !_hdrOutputRebuildInFlight &&
            !_hdrNativeOutputAttemptGate.inFlight &&
            _lastHdrNativeOutputAttempt != nativeOutputAttempt) {
          _lastHdrNativeOutputAttempt = nativeOutputAttempt;
          final nativeOutputAttemptToken = _hdrNativeOutputAttemptGate.start();
          if (nativeOutputAttemptToken == null) return;
          unawaited(
            _setHdrColorSpace(player, sourceGeneration: sourceGeneration)
                .then((applied) {
                  if (sourceGeneration != _hdrSourceGeneration) return;
                  if (applied) {
                    _hdrCapabilities = _hdrCapabilities.copyWith(
                      nativeOutput: true,
                      nativeOutputCapable: true,
                      nativeOutputActive: true,
                      decoderHdr: true,
                      unsupportedReason: 'native-dataspace-applied',
                    );
                    _hdrDecision = HdrDecision.choose(
                      mode: Pref.hdrMode,
                      source: _hdrSource,
                      capabilities: _hdrCapabilities,
                      hwdec: hwdec ?? 'auto',
                      allowDolbyVisionNative: _allowDiagnosticDolbyVisionNative,
                    );
                    debugPrint(
                      'HDR native decision applied: '
                      'output=${_hdrDecision.output.name}, '
                      'surface=${_hdrDecision.surface}, '
                      'sourceProcessing=${_hdrDecision.sourceProcessing}, '
                      'nativeOutputActive=${_hdrCapabilities.nativeOutputActive}',
                    );
                    unawaited(_applyHdrOutputParameters(player));
                  } else if (_hdrDecision.useHcpp) {
                    _hdrCapabilities = _hdrCapabilities.copyWith(
                      hcpp: false,
                      unsupportedReason: 'hcpp-dataspace-failed',
                    );
                    _hdrDecision = HdrDecision.choose(
                      mode: Pref.hdrMode,
                      source: _hdrSource,
                      capabilities: _hdrCapabilities,
                      hwdec: hwdec ?? 'auto',
                      allowDolbyVisionNative: _allowDiagnosticDolbyVisionNative,
                    );
                    _requestHdrOutputRebuild(
                      hcpp: false,
                      surfaceView: true,
                    );
                  }
                  debugPrint(
                    'HDR dataspace ${applied ? 'applied' : 'fallback'}: '
                    '${_hdrSource.transfer.name}',
                  );
                })
                .whenComplete(() {
                  // The completion belongs to this token even when its source
                  // has become stale.  Clearing only the matching token both
                  // releases a stale attempt and preserves any later one.
                  _hdrNativeOutputAttemptGate.complete(
                    nativeOutputAttemptToken,
                  );
                }),
          );
        }
      }),
      stream.buffering.listen((bool buffering) {
        PlayerTouchTrace.message(
          'player-state buffering=$buffering generation=$sourceGeneration '
          'position=${videoPlayerController?.state.position}',
        );
        isBuffering.value = buffering;
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          buffering,
          isLive,
        );
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        if (kDebugMode) {
          debugPrint('[OhosPlaybackTrace] stream.error event=$event');
        }
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Future.delayed(
              const Duration(milliseconds: 3000),
              () => refreshPlayer(reason: 'live-stream-error'),
            );
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Future.delayed(const Duration(milliseconds: 3000), () {
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                if (isBuffering.value && buffered.value == 0) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  refreshPlayer(reason: 'vod-buffer-timeout');
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    Future<void> seek() async {
      if (isSeek) {
        /// 拖动进度条调节时，不等待第一帧，防止抖动
        await _videoPlayerController?.stream.buffer.first;
      }
      danmakuController?.clear();
      try {
        await _videoPlayerController?.seek(position);
      } catch (e) {
        if (kDebugMode) debugPrint('seek failed: $e');
      }
    }

    if (duration.value != 0) {
      seek();
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek();
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) {
      return;
    }

    await _videoPlayerController?.setRate(speed);
    _playbackSpeed.value = speed;
    if (danmakuController != null) {
      try {
        DanmakuOption currentOption = danmakuController!.option;
        double defaultDuration = currentOption.duration * lastPlaybackSpeed;
        double defaultStaticDuration =
            currentOption.staticDuration * lastPlaybackSpeed;
        DanmakuOption updatedOption = currentOption.copyWith(
          duration: defaultDuration / speed,
          staticDuration: defaultStaticDuration / speed,
        );
        danmakuController!.updateOption(updatedOption);
      } catch (_) {}
    }
  }

  // 还原默认速度
  double playSpeedDefault = Pref.playSpeedDefault;
  Future<void> setDefaultSpeed() async {
    await _videoPlayerController?.setRate(playSpeedDefault);
    _playbackSpeed.value = playSpeedDefault;
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      // await seekTo(Duration.zero);
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus.value = PlayerStatus.playing;
    // screenManager.setOverlays(false);
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus.value = PlayerStatus.paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekEnd() {
    if (seekToPos != null) {
      feedBack();
    }
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    PlayerTouchTrace.message(
      'fullscreen commit target=$val before=${isFullScreen.value} '
      'vertical=$_isVertical owner=${_fullScreenOwner.generation}',
    );
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
    FullScreenOwnerToken? owner,
  }) {
    // A vertical source is already presented in the device's natural portrait
    // layout. Fullscreen must not turn it into a landscape surface merely
    // because the global fullscreen preference or a stale orientation event
    // requests rotation.
    if (isVertical && orientation == null) {
      debugPrint(
        '[FullscreenTrace] changeOrientation vertical=true '
        'mode=$mode request=null -> portrait',
      );
      return portraitUpMode(owner: owner ?? _fullScreenOwner);
    }
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode(owner: owner ?? _fullScreenOwner);
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode(owner: owner ?? _fullScreenOwner);
        } else {
          return landscapeLeftMode(owner: owner ?? _fullScreenOwner);
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode(owner: owner ?? _fullScreenOwner);
        } else {
          return landscapeRightMode(owner: owner ?? _fullScreenOwner);
        }
      }
    }
  }

  // 全屏
  final FullScreenRequestQueue _fullScreenRequestQueue =
      FullScreenRequestQueue();
  bool _fsNeedsReconciliation = false;
  bool _fsDisposed = false;
  bool _fsCleanupInFlight = false;
  // Tracks the platform effect actually applied by this owner. It must not
  // be inferred from the current source orientation, which can change while
  // the player remains logically fullscreen.
  bool _nativeFullScreenEffectActive = false;
  int _fullScreenRequestId = 0;

  void _scheduleInitialFullScreenPlatformReconciliation() {
    final canHaveNativeFullscreen =
        PlatformUtils.isMobile ||
        PlatformUtils.isDesktop ||
        Platform.operatingSystem == 'ohos';
    if (!canHaveNativeFullscreen) return;
    _fsNeedsReconciliation = true;
    unawaited(
      _fullScreenRequestQueue.enqueue(
        const FullScreenRequest(
          status: false,
          inAppFullScreen: false,
          orientation: null,
          isManualFS: false,
        ),
        isAlive: _isFullScreenTransactionAlive,
        isAtTarget: (target) =>
            !_fsNeedsReconciliation && isFullScreen.value == target,
        execute: _executeFullScreenRequest,
        commit: (target) {
          _fsNeedsReconciliation = false;
          if (_isFullScreenTransactionAlive()) _setFullScreen(target);
        },
      ),
    );
  }

  bool _isFullScreenTransactionAlive() =>
      !_fsDisposed &&
      _fullScreenOwner.isCurrent &&
      !_isCloseAll &&
      _playerCount > 0;

  Future<bool> _runFullScreenPlatformStep(
    Future<void>? Function() start,
  ) async {
    if (!_isFullScreenTransactionAlive()) return false;
    final operation = start();
    if (operation == null) return _isFullScreenTransactionAlive();
    if (!_isFullScreenTransactionAlive()) return false;
    await operation;
    return _isFullScreenTransactionAlive();
  }

  Future<bool> _executeFullScreenRequest(FullScreenRequest request) async {
    if (!_isFullScreenTransactionAlive()) return false;
    isManualFS = request.isManualFS;
    final requestId =
        'owner-${_fullScreenOwner.generation}-'
        '${++_fullScreenRequestId}-${request.status ? 'enter' : 'exit'}';
    final requestedOrientation = request.status && isVertical
        ? null
        : request.orientation;
    debugPrint(
      '[FullscreenTrace] execute status=${request.status} '
      'vertical=$isVertical mode=$mode '
      'requested=${request.orientation} effective=$requestedOrientation '
      'requestId=$requestId',
    );
    try {
      if (request.status) {
        if (PlatformUtils.isMobile) {
          if (!await _runFullScreenPlatformStep(
            () => hideSystemBar(owner: _fullScreenOwner),
          )) {
            return false;
          }
          if (!await _runFullScreenPlatformStep(
            () => changeOrientation(
              isVertical: isVertical,
              orientation: requestedOrientation,
              owner: _fullScreenOwner,
            ),
          )) {
            return false;
          }
          if (requestedOrientation == null && mode == .none) {
            debugPrint('Fullscreen enter: orientation already satisfied');
          }
        } else {
          if (Platform.operatingSystem == 'ohos' && isVertical) {
            // OHOS portrait playback is already in the desired portrait
            // window. Keep this product-specific path layout-only; desktop
            // platforms still need their native window fullscreen even when
            // the video itself is portrait.
            debugPrint(
              '[FullscreenTrace] vertical OHOS fullscreen: layout-only, '
              'no native window/system-bar effect',
            );
          } else {
            if (!await _runFullScreenPlatformStep(() async {
              // Mark the cleanup obligation before the platform call. The
              // native window may have changed and then throw, or complete
              // after dispose makes the transaction return false.
              if (!request.inAppFullScreen) {
                _nativeFullScreenEffectActive = true;
              }
              await enterDesktopFullScreen(
                inAppFullScreen: request.inAppFullScreen,
                landscape: true,
                owner: _fullScreenOwner,
                requestId: requestId,
              );
            })) {
              return false;
            }
          }
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            if (!await _runFullScreenPlatformStep(
              () => showSystemBar(owner: _fullScreenOwner),
            )) {
              return false;
            }
          }
          if (request.orientation == null && mode == .none) {
            debugPrint('Fullscreen exit: rotation not managed by player');
          } else if (!await _runFullScreenPlatformStep(
            () => resetScreenRotation(owner: _fullScreenOwner),
          )) {
            return false;
          }
        } else {
          final shouldExitNative =
              _nativeFullScreenEffectActive || _fsNeedsReconciliation;
          if (!shouldExitNative) {
            debugPrint(
              '[FullscreenTrace] fullscreen exit: no native effect owned by '
              'this controller',
            );
          } else {
            if (Platform.operatingSystem == 'ohos') {
              debugPrint(
                'Fullscreen exit: native OHOS request '
                'allowLandscape=$horizontalScreen',
              );
            }
            if (!await _runFullScreenPlatformStep(
              () => exitDesktopFullScreen(
                owner: _fullScreenOwner,
                allowLandscape: horizontalScreen,
                requestId: requestId,
              ),
            )) {
              return false;
            }
            _nativeFullScreenEffectActive = false;
          }
        }
      }
      return _isFullScreenTransactionAlive();
    } catch (error, stackTrace) {
      // The platform may have completed an earlier step (for example, hiding
      // system bars) before a later step failed. Keep the logical state at its
      // last committed value and force the next request through the platform
      // path so it can reconcile that partial result.
      _fsNeedsReconciliation = true;
      debugPrint('Fullscreen transaction failed: $error');
      if (kDebugMode) debugPrint(stackTrace.toString());
      return false;
    }
  }

  Future<void> _restoreFullScreenPlatformState(
    Future<void> queueSettled,
    FullScreenOwnerToken owner,
  ) async {
    await restoreFullScreenPlatformState(
      queueSettled: queueSettled,
      owner: owner,
      // OHOS enters fullscreen through the media-kit native window backend,
      // which is the same backend exposed by exitDesktopFullScreen below.
      // Cleanup must be selected by the backend actually used, not by the
      // unrelated desktop platform classification.
      desktop: (PlatformUtils.isDesktop || Platform.operatingSystem == 'ohos')
          ? (owner) async {
              if (!_nativeFullScreenEffectActive && !_fsNeedsReconciliation) {
                return;
              }
              await exitDesktopFullScreen(
                owner: owner,
                allowLandscape: horizontalScreen,
              );
              _nativeFullScreenEffectActive = false;
              _fsNeedsReconciliation = false;
            }
          : null,
      orientation: (owner) => resetScreenRotation(owner: owner),
      // OHOS native fullscreen owns the window system bars through the
      // media-kit channel. Calling the generic SystemChrome restoration from
      // dispose can remain pending after the player page is detached and
      // block the process-wide fullscreen queue for the next owner.
      systemBar: Platform.operatingSystem == 'ohos'
          ? (_) => null
          : (owner) => showSystemBar(owner: owner),
      onError: (step, error, stackTrace) {
        debugPrint('Fullscreen disposal cleanup $step failed: $error');
        if (kDebugMode) debugPrint(stackTrace.toString());
      },
    );
  }

  void _scheduleFullScreenDisposalCleanup() {
    if (_fsCleanupInFlight) return;
    _fsCleanupInFlight = true;
    unawaited(
      () async {
        try {
          await _restoreFullScreenPlatformState(
            _fullScreenRequestQueue.cancel(),
            _fullScreenOwner,
          );
        } catch (error, stackTrace) {
          debugPrint('Fullscreen disposal cleanup aborted: $error');
          if (kDebugMode) debugPrint(stackTrace.toString());
        } finally {
          // A failed cleanup must not permanently disable a later retry.
          _fsCleanupInFlight = false;
        }
      }(),
    );
  }

  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip || !_isFullScreenTransactionAlive()) return;
    PlayerTouchTrace.fullscreenMessage(
      'trigger status=$status inApp=$inAppFullScreen '
      'manual=$isManualFS current=${isFullScreen.value} '
      'vertical=$_isVertical',
    );
    final request = FullScreenRequest(
      status: status,
      inAppFullScreen: inAppFullScreen,
      orientation: orientation,
      isManualFS: isManualFS,
    );
    final completion = _fullScreenRequestQueue.enqueue(
      request,
      isAlive: _isFullScreenTransactionAlive,
      isAtTarget: (target) =>
          !_fsNeedsReconciliation && isFullScreen.value == target,
      execute: _executeFullScreenRequest,
      commit: (target) {
        _fsNeedsReconciliation = false;
        if (_isFullScreenTransactionAlive()) _setFullScreen(target);
      },
    );
    await completion;
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation({FullScreenOwnerToken? owner}) {
    if (horizontalScreen) {
      return fullMode(owner: owner ?? _fullScreenOwner);
    } else {
      return portraitUpMode(owner: owner ?? _fullScreenOwner);
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    _fsDisposed = true;
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    final isLastPlayer = _isCloseAll || _playerCount <= 1;
    debugPrint(
      '[FullscreenPlatformTrace] dispose owner=${_fullScreenOwner.generation} '
      'isLast=$isLastPlayer playerCount=$_playerCount closeAll=$_isCloseAll',
    );
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    // Everything below belongs to the shared Player.  A non-last reference
    // must only decrement its count: it cannot cancel shared listeners or
    // invalidate an output rebuild that the remaining reference still owns.
    _videoOutputTransactionGeneration++;
    _fsDisposed = true;
    _scheduleFullScreenDisposalCleanup();
    _hdrDisplaySubscription?.cancel();
    _hdrDisplaySubscription = null;
    cancelLongPressTimer();
    _cancelSubForSeek();

    // Window color mode is process-wide on Android. Do not leave a disposed
    // HDR player forcing the next page's SDR content through HDR output.
    unawaited(HdrPlatform.resetOutput());
    if (Platform.isAndroid) {
      unawaited(HdrAndroid.setWindowHdrMode(hdr: false));
    }
    _playerCount = 0;
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint?.release();
      AndroidHelper$ToDart.onUserLeaveHint = null;
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    if (playerStatus.isPlaying) {
      WakelockPlus.disable();
    }
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  Future<void> takeScreenshot() async {
    SmartDialog.showToast('截图中');
    final time = DurationUtils.formatDuration(
      positionInMilliseconds / 1000,
    ).replaceAll(':', '-');
    final imageBytes = await videoPlayerController?.screenshot();
    if (imageBytes != null) {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final image = frame.image;
      SmartDialog.showToast('点击弹窗保存截图');
      showDialog(
        context: Get.context!,
        builder: (context) => GestureDetector(
          onTap: () async {
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              ImageUtils.saveScreenShot(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
          },
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 5,
                      color: ColorScheme.of(context).surface,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: RawImage(image: image),
                  ),
                ),
              ),
            ),
          ),
        ),
      ).whenComplete(image.dispose);
    } else {
      SmartDialog.showToast('截图失败');
    }
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
