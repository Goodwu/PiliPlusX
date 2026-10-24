import 'dart:async' show Completer, Future, unawaited;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart' show DeviceOrientation;

class FullScreenRequest {
  const FullScreenRequest({
    required this.status,
    required this.inAppFullScreen,
    required this.orientation,
    required this.isManualFS,
  });

  final bool status;
  final bool inAppFullScreen;
  final DeviceOrientation? orientation;
  final bool isManualFS;
}

/// Serializes fullscreen requests for one player owner.
///
/// A request already executing cannot be forcefully interrupted because the
/// platform APIs do not expose cancellation. [cancel] therefore makes the
/// queue stop at the current await: it drops the pending request and prevents
/// any commit or subsequent request from starting. The owner must also make
/// [isAlive] return false during disposal so the executor can stop its own
/// platform-step sequence.
class FullScreenRequestQueue {
  FullScreenRequest? _pending;
  Completer<void>? _completion;
  bool _processing = false;
  bool _cancelled = false;

  bool get isProcessing => _processing;

  Future<void> enqueue(
    FullScreenRequest request, {
    required bool Function() isAlive,
    required bool Function(bool status) isAtTarget,
    required Future<bool> Function(FullScreenRequest request) execute,
    required void Function(bool status) commit,
  }) {
    if (_cancelled || !isAlive()) return Future<void>.value();
    if (_processing) {
      _pending = request;
      return _completion!.future;
    }
    if (isAtTarget(request.status)) return Future<void>.value();

    _processing = true;
    final completion = Completer<void>();
    _completion = completion;
    unawaited(
      _drain(
        request,
        isAlive: isAlive,
        isAtTarget: isAtTarget,
        execute: execute,
        commit: commit,
      ),
    );
    return completion.future;
  }

  Future<void> _drain(
    FullScreenRequest request, {
    required bool Function() isAlive,
    required bool Function(bool status) isAtTarget,
    required Future<bool> Function(FullScreenRequest request) execute,
    required void Function(bool status) commit,
  }) async {
    try {
      var current = request;
      while (!_cancelled && isAlive()) {
        if (!isAtTarget(current.status)) {
          var succeeded = false;
          try {
            succeeded = await execute(current);
          } catch (error, stackTrace) {
            debugPrint('Fullscreen transaction failed: $error');
            if (kDebugMode) debugPrint(stackTrace.toString());
          }
          if (!_cancelled && succeeded && isAlive()) {
            commit(current.status);
          }
        }

        if (_cancelled || !isAlive()) break;
        final next = _pending;
        _pending = null;
        if (next == null) break;
        current = next;
      }
    } finally {
      _processing = false;
      final completion = _completion;
      _completion = null;
      completion?.complete();
    }
  }

  /// Cancels pending work and prevents the active transaction from advancing.
  /// The currently awaited platform call is allowed to settle; it cannot be
  /// cancelled through Flutter's platform-channel API.
  Future<void> cancel() {
    _cancelled = true;
    _pending = null;
    return _completion?.future ?? Future<void>.value();
  }
}
