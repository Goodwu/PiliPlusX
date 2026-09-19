import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show debugPrintSynchronously, kDebugMode, kProfileMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Minimal player touch tracing. Enable explicitly with
/// `--dart-define=PILIPLUS_PLAYER_TOUCH_TRACE=true` when needed.
abstract final class PlayerTouchTrace {
  static const bool _explicitlyEnabled = bool.fromEnvironment(
    'PILIPLUS_PLAYER_TOUCH_TRACE',
    defaultValue: false,
  );
  // Kept separately from the normal trace switch so a diagnostic HAP can
  // prove that its dart-defines reached this kernel snapshot.  It is false in
  // every normal build and does not alter production input handling.
  static const bool _configurationProbe = bool.fromEnvironment(
    'PILIPLUS_PLAYER_TOUCH_TRACE_PROBE',
    defaultValue: false,
  );

  static bool get enabled =>
      _explicitlyEnabled ||
      _configurationProbe ||
      (kDebugMode && Platform.operatingSystem == 'ohos');

  static bool _startupLogged = false;
  static int _globalPointerRouteUsers = 0;
  static const bool _processLiveTest =
      kDebugMode &&
      bool.fromEnvironment(
        'PILIPLUS_PROCESS_LIVE_TEST',
        defaultValue: false,
      );
  static void Function(int pointer)? _processLiveTestOnDown;
  static Timer? _processLiveTestTimer;
  static final Set<int> _activePointerIds = <int>{};
  static final Set<int> _moveLoggedPointerIds = <int>{};

  // Flutter's default debugPrint is deliberately throttled.  That is useful
  // for ordinary diagnostics, but it can leave an action's causal markers
  // queued for minutes behind high-frequency trace output.  This class is
  // enabled only by an explicit diagnostic switch (or debug OHOS), so emit
  // its bounded markers synchronously to preserve trial attribution.
  static void _emit(String line) => debugPrintSynchronously(line);

  /// Whether the diagnostic lifecycle probe is still inside a real pointer
  /// sequence. The probe must never navigate after the originating touch has
  /// already ended.
  static bool get hasActivePointer => _activePointerIds.isNotEmpty;

  static bool isActivePointer(int pointer) =>
      _activePointerIds.contains(pointer);

  /// Number of live player states using the observation-only global route.
  /// Exposed for lifecycle tests; it has no effect on pointer handling.
  static int get globalPointerRouteUsers => _globalPointerRouteUsers;

  /// Arms a one-shot, observation-triggered lifecycle probe. The callback is
  /// intentionally supplied by the owning page so the probe exercises the
  /// normal route/page lifecycle; it never calls the embedding Cancel path.
  static void armProcessLiveTest(void Function(int pointer) onDown) {
    if (!_processLiveTest || !enabled) return;
    _processLiveTestTimer?.cancel();
    _processLiveTestOnDown = onDown;
    _emit('[PlayerTouchTrace] process-live-test armed');
  }

  static void disarmProcessLiveTest() {
    _processLiveTestTimer?.cancel();
    _processLiveTestTimer = null;
    _processLiveTestOnDown = null;
  }

  static void logStartup() {
    if (_startupLogged || !enabled) return;
    _startupLogged = true;
    _emit(
      formatStartup(
        build: kDebugMode
            ? 'debug'
            : kProfileMode
            ? 'profile'
            : 'release',
        os: Platform.operatingSystem,
        traceEnabled: enabled,
        configurationProbe: _configurationProbe,
      ),
    );
  }

  static String formatStartup({
    required String build,
    required String os,
    required bool traceEnabled,
    bool configurationProbe = false,
  }) =>
      '[PlayerTouchTrace] startup build=$build os=$os '
      'traceEnabled=$traceEnabled configurationProbe=$configurationProbe';

  /// Installs one observation-only route while one or more player states live.
  static void registerGlobalPointerRoute() {
    _globalPointerRouteUsers++;
    if (_globalPointerRouteUsers != 1) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointerEvent);
    if (enabled) {
      _emit('[PlayerTouchTrace] global route registered');
    }
  }

  /// Removes the global route after the last player state is disposed.
  static void unregisterGlobalPointerRoute() {
    if (_globalPointerRouteUsers == 0) return;
    _globalPointerRouteUsers--;
    if (_globalPointerRouteUsers != 0) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _onGlobalPointerEvent,
    );
    _activePointerIds.clear();
    _moveLoggedPointerIds.clear();
    if (enabled) {
      _emit('[PlayerTouchTrace] global route removed');
    }
  }

  static void _onGlobalPointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _activePointerIds.add(event.pointer);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _activePointerIds.remove(event.pointer);
      _moveLoggedPointerIds.remove(event.pointer);
    }
    if (event is PointerDownEvent && _processLiveTestOnDown != null) {
      final callback = _processLiveTestOnDown!;
      _processLiveTestOnDown = null;
      _processLiveTestTimer = Timer(const Duration(milliseconds: 150), () {
        _processLiveTestTimer = null;
        _emit('[PlayerTouchTrace] process-live-test fired');
        callback(event.pointer);
      });
    }
    final stage = switch (event) {
      PointerDownEvent() => 'global route down',
      PointerUpEvent() => 'global route up',
      PointerCancelEvent() => 'global route cancel',
      _ => null,
    };
    if (event is PointerMoveEvent && _moveLoggedPointerIds.add(event.pointer)) {
      PlayerTouchTrace.event(stage: 'global route first-move', event: event);
    }
    if (stage == null) return;
    PlayerTouchTrace.event(
      stage: stage,
      event: event,
    );
  }

  static void event({
    required String stage,
    PointerEvent? event,
    int? pointer,
    int? viewId,
    int? device,
    Offset? position,
    Offset? globalPosition,
    PointerDeviceKind? kind,
  }) {
    if (!enabled) return;
    final actualPointer = event?.pointer ?? pointer;
    final actualViewId = event?.viewId ?? viewId ?? 0;
    final actualDevice = event?.device ?? device ?? 0;
    final actualPosition = event?.localPosition ?? position ?? Offset.zero;
    final actualGlobalPosition =
        event?.position ?? globalPosition ?? position ?? Offset.zero;
    final actualKind = event?.kind ?? kind ?? PointerDeviceKind.touch;
    _emit(
      format(
        stage: stage,
        pointer: actualPointer ?? -1,
        viewId: actualViewId,
        device: actualDevice,
        position: actualPosition,
        globalPosition: actualGlobalPosition,
        kind: actualKind,
      ),
    );
  }

  static String format({
    required String stage,
    required int pointer,
    required int viewId,
    required int device,
    required Offset position,
    required Offset globalPosition,
    required PointerDeviceKind kind,
  }) =>
      '[PlayerTouchTrace] ${DateTime.now().toIso8601String()} '
      'stage=$stage pointer=$pointer viewId=$viewId device=$device '
      'position=(${position.dx.toStringAsFixed(1)},'
      '${position.dy.toStringAsFixed(1)}) '
      'global=(${globalPosition.dx.toStringAsFixed(1)},'
      '${globalPosition.dy.toStringAsFixed(1)}) kind=${kind.name}';

  /// Emits a diagnostic-only player interaction message without requiring a
  /// synthetic pointer event. This keeps gesture decisions and side effects
  /// observable in the same hilog stream as the pointer lifecycle.
  static void message(String value) {
    if (!enabled) return;
    _emit('[PlayerTouchTrace] ${DateTime.now().toIso8601String()} $value');
  }

  /// Emits the fullscreen transaction marker through the same synchronous
  /// diagnostic path while preserving its existing parser contract.
  static void fullscreenMessage(String value) {
    if (!enabled) return;
    _emit(formatFullscreen(value));
  }

  static String formatFullscreen(String value) => '[FullscreenTrace] $value';

  /// Formats a layout snapshot independently of a live render tree.
  static String formatBounds({
    required String stage,
    required Size size,
    required Rect globalBounds,
  }) =>
      '[PlayerTouchTrace] bounds stage=$stage '
      'size=(${size.width.toStringAsFixed(1)},'
      '${size.height.toStringAsFixed(1)}) '
      'globalBounds=(${globalBounds.left.toStringAsFixed(1)},'
      '${globalBounds.top.toStringAsFixed(1)},'
      '${globalBounds.right.toStringAsFixed(1)},'
      '${globalBounds.bottom.toStringAsFixed(1)})';

  /// Logs a render-box snapshot only when the object is attached and laid out.
  static void logRenderBoxBounds({
    required String stage,
    required RenderBox? renderBox,
  }) {
    if (!enabled) return;
    final line = renderBoxBounds(stage: stage, renderBox: renderBox);
    if (line != null) _emit(line);
  }

  static String? renderBoxBounds({
    required String stage,
    required RenderBox? renderBox,
  }) {
    if (renderBox == null || !renderBox.attached || !renderBox.hasSize) {
      return null;
    }
    final size = renderBox.size;
    final topLeft = renderBox.localToGlobal(Offset.zero);
    final bottomRight = renderBox.localToGlobal(
      Offset(size.width, size.height),
    );
    final globalBounds = Rect.fromPoints(topLeft, bottomRight);
    if (!size.isFinite || !globalBounds.isFinite) return null;
    return formatBounds(stage: stage, size: size, globalBounds: globalBounds);
  }

  static void logRenderObjectBounds({
    required String stage,
    required BuildContext? context,
  }) {
    if (!enabled || context == null) return;
    final renderObject = context.findRenderObject();
    logRenderBoxBounds(
      stage: stage,
      renderBox: renderObject is RenderBox ? renderObject : null,
    );
  }
}
