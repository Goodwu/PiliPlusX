import 'dart:async';
import 'dart:convert';

/// Reads mpv's pacing and drop properties without changing player options.
class FramePacingPropertyReadback {
  static const properties = <String>[
    'video-sync',
    'video-timing-offset',
    'display-fps',
    'estimated-display-fps',
    'container-fps',
    'estimated-vf-fps',
    'hwdec-current',
    'decoder-frame-drop-count',
    'frame-drop-count',
    'mistimed-frame-count',
    'vo-delayed-frame-count',
    'avsync',
    'total-avsync-change',
  ];

  static Future<Map<String, Object?>?> read({
    required Future<String> Function(String property) getProperty,
    required bool Function() isCurrent,
    required int playerHandle,
    required int sourceGeneration,
    required int Function() monotonicMilliseconds,
    DateTime Function()? nowUtc,
  }) async {
    final now = nowUtc ?? DateTime.now;
    final result = <String, Object?>{};
    for (final property in properties) {
      if (!isCurrent()) return null;
      final startedAt = now().toUtc();
      final startedMonotonic = monotonicMilliseconds();
      String? value;
      String? errorType;
      try {
        value = await getProperty(property);
      } catch (error) {
        errorType = error.runtimeType.toString();
      }
      final finishedAt = now().toUtc();
      final finishedMonotonic = monotonicMilliseconds();
      // Do not continue to the next native call or return a partial stale
      // batch after source replacement or native player teardown.
      if (!isCurrent()) return null;
      final hasValue = value != null && value.isNotEmpty;
      result[property] = <String, Object?>{
        'status': hasValue ? 'available' : 'unavailable',
        if (hasValue) 'value': value,
        if (!hasValue)
          'reason': errorType == null
              ? 'empty-or-unknown-property'
              : 'query-error',
        'errorType': ?errorType,
        'queryStartedAtUtc': startedAt.toIso8601String(),
        'queryEndedAtUtc': finishedAt.toIso8601String(),
        'queryStartedMonotonicMilliseconds': startedMonotonic,
        'queryEndedMonotonicMilliseconds': finishedMonotonic,
        'playerHandle': playerHandle,
        'sourceGeneration': sourceGeneration,
      };
    }
    return result;
  }
}

/// Fixed production bounds for the opt-in frame pacing trace.
class FramePacingDiagnosticWindow {
  FramePacingDiagnosticWindow({
    required this.startedAt,
    this.interval = const Duration(seconds: 1),
    this.maximumDuration = const Duration(seconds: 180),
    this.maximumSamples = 180,
  });

  final DateTime startedAt;
  final Duration interval;
  final Duration maximumDuration;
  final int maximumSamples;

  DateTime? _lastSampleAt;
  int _sampleCount = 0;

  int get sampleCount => _sampleCount;

  bool get isAtSampleLimit => _sampleCount >= maximumSamples;

  bool isExpiredAt(DateTime now) =>
      !now.isBefore(startedAt) && now.difference(startedAt) >= maximumDuration;

  bool takeSampleAt(DateTime now) {
    if (now.isBefore(startedAt) ||
        isExpiredAt(now) ||
        isAtSampleLimit ||
        (_lastSampleAt != null && now.difference(_lastSampleAt!) < interval)) {
      return false;
    }
    _lastSampleAt = now;
    _sampleCount++;
    return true;
  }
}

/// Emits a bounded JSONL sample stream and owns its timer lifecycle.
class FramePacingDiagnosticSampler {
  static const environmentVariable = 'PILIPLUSX_FRAME_PACING_DIAGNOSTICS';

  static bool isEnabled(
    Map<String, String> environment, {
    required bool isMacOS,
  }) => isMacOS && environment[environmentVariable] == '1';

  FramePacingDiagnosticSampler({
    required this.sample,
    required this.writeLine,
    this.readProperties,
    this.isCurrent,
    DateTime Function()? now,
    this.interval = const Duration(seconds: 1),
    this.maximumDuration = const Duration(seconds: 180),
    this.maximumSamples = 180,
    this.onStop,
  }) : _now = now ?? DateTime.now;

  final Map<String, Object?> Function() sample;
  final void Function(String line) writeLine;
  final Future<Map<String, Object?>?> Function()? readProperties;
  final bool Function()? isCurrent;
  final DateTime Function() _now;
  final Duration interval;
  final Duration maximumDuration;
  final int maximumSamples;
  final void Function()? onStop;

  Timer? _timer;
  Timer? _deadlineTimer;
  FramePacingDiagnosticWindow? _window;
  final Stopwatch _monotonicClock = Stopwatch();
  bool _sampling = false;
  bool _stopped = true;

  bool get isRunning => !_stopped;
  int get sampleCount => _window?.sampleCount ?? 0;
  int get monotonicMilliseconds => _monotonicClock.elapsedMilliseconds;

  bool start() {
    if (!_stopped) return false;
    _stopped = false;
    _monotonicClock
      ..reset()
      ..start();
    _window = FramePacingDiagnosticWindow(
      startedAt: _now(),
      interval: interval,
      maximumDuration: maximumDuration,
      maximumSamples: maximumSamples,
    );
    _deadlineTimer = Timer(maximumDuration, dispose);
    unawaited(_emitIfDue());
    if (!_stopped) {
      _timer = Timer.periodic(interval, (_) => unawaited(_emitIfDue()));
    }
    return true;
  }

  Future<void> _emitIfDue() async {
    if (_stopped || _sampling) return;
    if (!(isCurrent?.call() ?? true)) {
      dispose();
      return;
    }
    final now = _now();
    final window = _window!;
    if (!window.takeSampleAt(now)) {
      if (window.isAtSampleLimit || window.isExpiredAt(now)) dispose();
      return;
    }
    _sampling = true;
    try {
      final record = <String, Object?>{
        ...sample(),
        'sampledAtUtc': now.toUtc().toIso8601String(),
        'elapsedMilliseconds': now.difference(window.startedAt).inMilliseconds,
        'elapsedMonotonicMilliseconds': _monotonicClock.elapsedMilliseconds,
        'sampleIndex': window.sampleCount,
      };
      final read = readProperties;
      if (read != null) {
        final queryStartedAt = _now().toUtc();
        final queryStartedMonotonic = _monotonicClock.elapsedMilliseconds;
        Map<String, Object?>? properties;
        String? queryErrorType;
        try {
          properties = await read();
        } catch (error) {
          // Property diagnostics must never suppress ordinary state samples
          // or fail playback if the injected reader unexpectedly throws.
          queryErrorType = error.runtimeType.toString();
          properties = <String, Object?>{};
        }
        final queryEndedAt = _now().toUtc();
        final queryEndedMonotonic = _monotonicClock.elapsedMilliseconds;
        if (_stopped) return;
        if (!(isCurrent?.call() ?? true) || properties == null) {
          dispose();
          return;
        }
        record['mpvProperties'] = properties;
        record['mpvQueryBatch'] = <String, Object?>{
          'status': queryErrorType == null ? 'complete' : 'unavailable',
          'errorType': ?queryErrorType,
          'queryStartedAtUtc': queryStartedAt.toIso8601String(),
          'queryEndedAtUtc': queryEndedAt.toIso8601String(),
          'queryStartedMonotonicMilliseconds': queryStartedMonotonic,
          'queryEndedMonotonicMilliseconds': queryEndedMonotonic,
        };
      }
      if (_stopped) return;
      if (!(isCurrent?.call() ?? true)) {
        dispose();
        return;
      }
      writeLine(jsonEncode(record));
    } catch (_) {
      dispose();
    } finally {
      _sampling = false;
    }
    if (window.isAtSampleLimit) dispose();
  }

  void dispose() {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    onStop?.call();
  }
}
