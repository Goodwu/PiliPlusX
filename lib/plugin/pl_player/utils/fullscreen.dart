import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/utils/device_utils.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show SystemChrome, MethodChannel, SystemUiOverlay, DeviceOrientation;

/// Identifies the controller that currently owns process-wide fullscreen state.
///
/// Platform calls cannot be cancelled once sent over a channel. The owner is
/// therefore checked both before a queued call starts and before its result is
/// committed to the helper's cache. A newer controller supersedes an older
/// owner without having to interrupt the older platform call.
class FullScreenOwnerToken {
  FullScreenOwnerToken._(this.generation);

  final int generation;

  bool get isCurrent => identical(_currentOwner, this);
}

typedef FullScreenRestoreStep = Future<void>? Function(
  FullScreenOwnerToken owner,
);

/// Restores process-wide fullscreen state one platform step at a time.
///
/// Each step checks ownership immediately before it starts and has its own
/// error boundary. A failed orientation restore must not prevent the system
/// bars from being restored. [onError] keeps failures observable to the
/// controller, while allowing a later cleanup invocation to retry them.
Future<void> restoreFullScreenPlatformState({
  required Future<void> queueSettled,
  required FullScreenOwnerToken owner,
  FullScreenRestoreStep? desktop,
  required FullScreenRestoreStep orientation,
  required FullScreenRestoreStep systemBar,
  void Function(String step, Object error, StackTrace stackTrace)? onError,
}) async {
  await queueSettled;
  if (!owner.isCurrent) return;

  Future<void> attempt(String step, FullScreenRestoreStep restore) async {
    if (!owner.isCurrent) return;
    try {
      final operation = restore(owner);
      if (operation != null) await operation;
    } catch (error, stackTrace) {
      onError?.call(step, error, stackTrace);
    }
  }

  if (desktop != null) {
    await attempt('desktop fullscreen', desktop);
  }
  await attempt('orientation', orientation);
  await attempt('system bars', systemBar);
}

int _nextOwnerGeneration = 0;
FullScreenOwnerToken? _currentOwner;
int _nextNativeFullscreenRequestId = 0;

String _newNativeFullscreenRequestId(
  FullScreenOwnerToken? owner,
  String operation,
) =>
    '$operation-${owner?.generation ?? 'none'}-${++_nextNativeFullscreenRequestId}';

FullScreenOwnerToken claimFullScreenOwner() {
  final owner = FullScreenOwnerToken._(++_nextOwnerGeneration);
  _currentOwner = owner;
  debugPrint(
    '[FullscreenPlatformTrace] claim-owner generation=${owner.generation}',
  );

  // These values belong to the previous controller until a new owner has
  // successfully applied its first platform state. Never let the new owner
  // inherit a cache entry that can cause its first hide/show/orientation step
  // to be skipped.
  _orientationOwner = null;
  _systemBarOwner = null;
  _desktopFullScreenOwner = null;
  return owner;
}

Future<void> _platformTail = Future<void>.value();

FullScreenOwnerToken? _ownerForCall(FullScreenOwnerToken? owner) {
  return owner ?? _currentOwner;
}

bool _owns(FullScreenOwnerToken? owner) {
  return owner == null ? _currentOwner == null : owner.isCurrent;
}

Future<void> _enqueuePlatformEffect(
  FullScreenOwnerToken? owner,
  String operationName,
  Future<void> Function() effect,
) {
  final ownerGeneration = owner?.generation;
  debugPrint(
    '[FullscreenPlatformTrace] enqueue operation=$operationName '
    'owner=$ownerGeneration',
  );
  final operation = _platformTail.then<void>((_) async {
    if (!_owns(owner)) {
      debugPrint(
        '[FullscreenPlatformTrace] start skipped stale-owner '
        'operation=$operationName owner=$ownerGeneration',
      );
      return;
    }
    debugPrint(
      '[FullscreenPlatformTrace] start operation=$operationName '
      'owner=$ownerGeneration',
    );
    await effect();
    debugPrint(
      '[FullscreenPlatformTrace] finish operation=$operationName '
      'owner=$ownerGeneration',
    );
  });
  // Keep later owners able to run even when an earlier platform call fails,
  // while returning the original error to the controller that owns it.
  _platformTail = operation.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {},
  );
  return operation;
}

bool _isDesktopFullScreen = false;
FullScreenOwnerToken? _desktopFullScreenOwner;

void _invalidateDesktopFullScreenCache(FullScreenOwnerToken? owner) {
  if (owner != null && _owns(owner)) {
    // A native call may have partially changed the window before failing.
    // Mark the result unknown so the next request cannot be deduplicated by
    // the stale producer-side cache.
    _isDesktopFullScreen = false;
    _desktopFullScreenOwner = null;
  }
}

@pragma('vm:notify-debugger-on-exception')
Future<void> enterDesktopFullScreen({
  bool inAppFullScreen = false,
  bool landscape = true,
  FullScreenOwnerToken? owner,
  String? requestId,
}) async {
  final transactionOwner = _ownerForCall(owner);
  if (inAppFullScreen || !_owns(transactionOwner)) {
    return;
  }
  final traceId =
      requestId ?? _newNativeFullscreenRequestId(transactionOwner, 'enter');
  await _enqueuePlatformEffect(transactionOwner, 'enter-native-fullscreen', () async {
    if (_desktopFullScreenOwner == transactionOwner && _isDesktopFullScreen) {
      debugPrint(
        '[FullscreenPlatformTrace] enter skipped cached=true '
        'owner=${transactionOwner?.generation}',
      );
      return;
    }
    debugPrint(
      '[FullscreenPlatformTrace] enter invoke owner=${transactionOwner?.generation} '
      'requestId=$traceId cached=$_isDesktopFullScreen '
      'cachedOwner=${_desktopFullScreenOwner?.generation}',
    );
    try {
      await const MethodChannel(
        'com.alexmercerind/media_kit_video',
      ).invokeMethod('Utils.EnterNativeFullscreen', {
        'landscape': landscape,
        'requestId': traceId,
      });
    } catch (_) {
      _invalidateDesktopFullScreenCache(transactionOwner);
      rethrow;
    }
    if (_owns(transactionOwner)) {
      _isDesktopFullScreen = true;
      _desktopFullScreenOwner = transactionOwner;
    }
  });
}

@pragma('vm:notify-debugger-on-exception')
Future<void> exitDesktopFullScreen({
  FullScreenOwnerToken? owner,
  bool allowLandscape = false,
  String? requestId,
}) async {
  final transactionOwner = _ownerForCall(owner);
  if (!_owns(transactionOwner)) {
    return;
  }
  final traceId =
      requestId ?? _newNativeFullscreenRequestId(transactionOwner, 'exit');
  await _enqueuePlatformEffect(transactionOwner, 'exit-native-fullscreen', () async {
    if (_desktopFullScreenOwner == transactionOwner && !_isDesktopFullScreen) {
      debugPrint(
        '[FullscreenPlatformTrace] exit skipped cached=false '
        'owner=${transactionOwner?.generation}',
      );
      return;
    }
    debugPrint(
      '[FullscreenPlatformTrace] exit invoke owner=${transactionOwner?.generation} '
      'requestId=$traceId cached=$_isDesktopFullScreen '
      'cachedOwner=${_desktopFullScreenOwner?.generation}',
    );
    try {
      await const MethodChannel(
        'com.alexmercerind/media_kit_video',
      ).invokeMethod('Utils.ExitNativeFullscreen', {
        'allowLandscape': allowLandscape,
        'requestId': traceId,
      });
    } catch (_) {
      _invalidateDesktopFullScreenCache(transactionOwner);
      rethrow;
    }
    if (_owns(transactionOwner)) {
      _isDesktopFullScreen = false;
      _desktopFullScreenOwner = transactionOwner;
    }
  });
}

List<DeviceOrientation>? _lastOrientation;
FullScreenOwnerToken? _orientationOwner;
Future<void>? _setPreferredOrientations(
  List<DeviceOrientation> orientations, {
  FullScreenOwnerToken? owner,
}) {
  final transactionOwner = _ownerForCall(owner);
  if (!_owns(transactionOwner)) return null;
  return _enqueuePlatformEffect(
    transactionOwner,
    'preferred-orientation',
    () async {
      if (_orientationOwner == transactionOwner &&
          _sameOrientation(_lastOrientation, orientations)) {
        return;
      }
      await SystemChrome.setPreferredOrientations(orientations);
      if (_owns(transactionOwner)) {
        _lastOrientation = orientations;
        _orientationOwner = transactionOwner;
      }
    },
  );
}

bool _sameOrientation(
  List<DeviceOrientation>? first,
  List<DeviceOrientation> second,
) {
  if (first == null || first.length != second.length) return false;
  for (var index = 0; index < second.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

Future<void>? portraitUpMode({FullScreenOwnerToken? owner}) {
  return _setPreferredOrientations(const [.portraitUp], owner: owner);
}

Future<void>? portraitDownMode({FullScreenOwnerToken? owner}) {
  return _setPreferredOrientations(const [.portraitDown], owner: owner);
}

Future<void>? landscapeLeftMode({FullScreenOwnerToken? owner}) {
  return _setPreferredOrientations(const [.landscapeLeft], owner: owner);
}

Future<void>? landscapeRightMode({FullScreenOwnerToken? owner}) {
  return _setPreferredOrientations(const [.landscapeRight], owner: owner);
}

Future<void>? fullMode({FullScreenOwnerToken? owner}) {
  return _setPreferredOrientations(
    const [.portraitUp, .portraitDown, .landscapeLeft, .landscapeRight],
    owner: owner,
  );
}

bool _showSystemBar = true;
FullScreenOwnerToken? _systemBarOwner;
bool get showSystemBar_ => _showSystemBar;
Future<void>? hideSystemBar({FullScreenOwnerToken? owner}) {
  final transactionOwner = _ownerForCall(owner);
  if (!_owns(transactionOwner)) {
    return null;
  }
  return _enqueuePlatformEffect(transactionOwner, 'hide-system-bar', () async {
    if (_systemBarOwner == transactionOwner && !_showSystemBar) return;
    await SystemChrome.setEnabledSystemUIMode(.immersiveSticky);
    if (_owns(transactionOwner)) {
      _showSystemBar = false;
      _systemBarOwner = transactionOwner;
    }
  });
}

//退出全屏显示
Future<void>? showSystemBar({FullScreenOwnerToken? owner}) {
  final transactionOwner = _ownerForCall(owner);
  if (!_owns(transactionOwner)) {
    return null;
  }
  return _enqueuePlatformEffect(transactionOwner, 'show-system-bar', () async {
    if (_systemBarOwner == transactionOwner && _showSystemBar) return;
    await SystemChrome.setEnabledSystemUIMode(
      Platform.isAndroid && DeviceUtils.sdkInt < 29 ? .manual : .edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    if (_owns(transactionOwner)) {
      _showSystemBar = true;
      _systemBarOwner = transactionOwner;
    }
  });
}
