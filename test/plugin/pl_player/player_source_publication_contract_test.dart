import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/plugin/pl_player/controller.dart')
      .readAsStringSync();

  test('only Android publishes the view callback before source open', () {
    final setDataSource = source.substring(
      source.indexOf('Future<void> setDataSource('),
      source.indexOf('\n  String? shadersDirPath;'),
    );
    final androidCallback = setDataSource.indexOf(
      'if (Platform.isAndroid) onInit?.call();',
    );
    final createController = setDataSource.indexOf(
      'await _createVideoController(',
    );

    expect(androidCallback, greaterThanOrEqualTo(0));
    expect(createController, greaterThan(androidCallback));
    expect(
      RegExp(r'onInit\?\.call\(\);')
          .allMatches(setDataSource.substring(0, createController))
          .length,
      1,
      reason: 'only Android may publish onInit before VideoController creation',
    );
  });

  test(
    'non-Android callback follows initialization and current-source guards',
    () {
      final setDataSource = source.substring(
        source.indexOf('Future<void> setDataSource('),
        source.indexOf('\n  String? shadersDirPath;'),
      );
      final initialize = setDataSource.indexOf('await _initializePlayer();');
      final callback = setDataSource.indexOf(
        'if (!Platform.isAndroid) onInit?.call();',
      );
      final guard = setDataSource.indexOf('_playerCount == 0', initialize);

      expect(initialize, greaterThanOrEqualTo(0));
      expect(guard, greaterThan(initialize));
      expect(callback, greaterThan(guard));
      expect(setDataSource.substring(guard, callback), contains('_fsDisposed'));
    },
  );

  test(
    'native-surface state binds only after the current pair is published',
    () {
      final createVideoController = source.substring(
        source.indexOf('Future<void> _createVideoController('),
        source.indexOf('\n  Future<void>? refreshPlayer('),
      );
      final publishPlayer = createVideoController.indexOf(
        '_videoPlayerController = initializedPlayer;',
      );
      final publishVideo = createVideoController.indexOf(
        '_videoController = videoController;',
      );
      final bind = createVideoController.indexOf(
        'unawaited(_bindNativeSurfaceState(videoController));',
      );
      final initPlayer = source.substring(
        source.indexOf('Future<_InitializedVideoPlayer?> _initPlayer('),
        source.indexOf('\n  /// 非 Android 平台的控制器配置'),
      );

      expect(publishPlayer, greaterThanOrEqualTo(0));
      expect(publishVideo, greaterThan(publishPlayer));
      expect(bind, greaterThan(publishVideo));
      expect(
        createVideoController.substring(publishVideo, bind),
        contains('if (videoController != null)'),
      );
      expect(initPlayer, isNot(contains('_bindNativeSurfaceState(')));
      expect(
        initPlayer,
        isNot(contains('_startListeners(')),
        reason: 'listeners belong to the final shared pair publication block',
      );
    },
  );

  test('listener subscriptions are owned incrementally during publication', () {
    final startListeners = source.substring(
      source.indexOf('void _startListeners('),
      source.indexOf('\n  /// 移除事件监听'),
    );
    final owner = startListeners.indexOf(
      '_subscriptions = subscriptionOwner.subscriptions;',
    );
    final registrations = startListeners.indexOf('_subscriptions = [', owner);
    final firstListener = startListeners.indexOf(
      'subscriptionOwner.track(',
      registrations,
    );
    final rollback = startListeners.indexOf(
      'subscriptionOwner.cancel();',
      firstListener,
    );
    final rethrowIndex = startListeners.indexOf(
      'rethrow;',
      rollback,
    );

    expect(owner, greaterThanOrEqualTo(0));
    expect(registrations, greaterThan(owner));
    expect(firstListener, greaterThan(registrations));
    expect(rollback, greaterThan(firstListener));
    expect(rethrowIndex, greaterThan(rollback));
    expect(
      startListeners,
      contains('identical(_subscriptions, subscriptionOwner.subscriptions)'),
    );
    expect(
      'subscriptionOwner.track('.allMatches(startListeners).length,
      startListeners.split('.listen(').length - 1,
      reason:
          'each stream listen must enter the owner before the next can throw',
    );
  });
}
