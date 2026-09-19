import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'deduplication is checked when the queued system-bar call runs',
    () async {
      final calls = <String>[];
      final hideStarted = Completer<void>();
      final releaseHide = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
                calls.add(call.method);
                if (calls.length == 2) {
                  hideStarted.complete();
                  await releaseHide.future;
                }
              }
              return null;
            },
          );

      try {
        final owner = claimFullScreenOwner();
        await showSystemBar(owner: owner);

        final hide = hideSystemBar(owner: owner)!;
        await hideStarted.future;

        // The cache still says "shown" while hide is in flight. This restore
        // must remain queued and re-check the cache after hide has committed.
        final restore = showSystemBar(owner: owner);
        expect(restore, isNotNull);

        releaseHide.complete();
        await Future.wait([hide, restore!]);

        expect(calls, [
          'SystemChrome.setEnabledSystemUIMode',
          'SystemChrome.setEnabledSystemUIMode',
          'SystemChrome.setEnabledSystemUIMode',
        ]);
        expect(showSystemBar_, isTrue);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      }
    },
  );

  test('a late old-owner restore cannot affect the new owner', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
              calls.add(call.method);
            }
            return null;
          },
        );

    try {
      final oldOwner = claimFullScreenOwner();
      await hideSystemBar(owner: oldOwner);

      // This represents disposal waiting for the old queue/platform call. It
      // completes after the replacement page has already applied its state.
      final oldCleanupSettled = Completer<void>();
      final oldCleanup = oldCleanupSettled.future.then<void>(
        (_) => showSystemBar(owner: oldOwner),
      );

      final newOwner = claimFullScreenOwner();
      await hideSystemBar(owner: newOwner);
      oldCleanupSettled.complete();
      await oldCleanup;

      // The new owner must not inherit the old cache, while the stale restore
      // must not show the system bars on the replacement page.
      expect(calls, [
        'SystemChrome.setEnabledSystemUIMode',
        'SystemChrome.setEnabledSystemUIMode',
      ]);
      expect(showSystemBar_, isFalse);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });

  test('old-owner cleanup cannot overwrite a replacement owner', () async {
    final calls = <String>[];
    final hideStarted = Completer<void>();
    final releaseHide = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
              calls.add(call.method);
              if (calls.length == 2) {
                hideStarted.complete();
                await releaseHide.future;
              }
            }
            return null;
          },
        );

    try {
      final oldOwner = claimFullScreenOwner();
      await showSystemBar(owner: oldOwner);

      final oldHide = hideSystemBar(owner: oldOwner)!;
      await hideStarted.future;
      final oldRestore = showSystemBar(owner: oldOwner);
      expect(oldRestore, isNotNull);

      final newOwner = claimFullScreenOwner();
      final newRestore = showSystemBar(owner: newOwner);
      expect(newRestore, isNotNull);

      releaseHide.complete();
      await Future.wait([oldHide, oldRestore!, newRestore!]);

      // The old queued restore is dropped after ownership changes. The new
      // owner still performs its own first restore despite the old cache.
      expect(calls, [
        'SystemChrome.setEnabledSystemUIMode',
        'SystemChrome.setEnabledSystemUIMode',
        'SystemChrome.setEnabledSystemUIMode',
      ]);
      expect(showSystemBar_, isTrue);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });

  test(
    'cleanup attempts system bars after orientation failure and can retry',
    () async {
      final calls = <String>[];
      final errors = <String>[];
      var failOrientation = true;
      final owner = claimFullScreenOwner();

      await restoreFullScreenPlatformState(
        queueSettled: Future<void>.value(),
        owner: owner,
        orientation: (_) async {
          calls.add('orientation');
          if (failOrientation) {
            throw StateError('orientation restore failed');
          }
        },
        systemBar: (_) async => calls.add('system bars'),
        onError: (step, error, stackTrace) {
          errors.add('$step: $error');
        },
      );

      expect(calls, ['orientation', 'system bars']);
      expect(errors, ['orientation: Bad state: orientation restore failed']);

      failOrientation = false;
      await restoreFullScreenPlatformState(
        queueSettled: Future<void>.value(),
        owner: owner,
        orientation: (_) async => calls.add('orientation'),
        systemBar: (_) async => calls.add('system bars'),
        onError: (step, error, stackTrace) {
          errors.add('$step: $error');
        },
      );

      expect(calls, [
        'orientation',
        'system bars',
        'orientation',
        'system bars',
      ]);
      expect(errors, ['orientation: Bad state: orientation restore failed']);
    },
  );

  test(
    'native fullscreen failure invalidates the deduplication cache',
    () async {
      var failEnter = true;
      var enterCalls = 0;
      const channel = MethodChannel('com.alexmercerind/media_kit_video');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async {
              if (call.method == 'Utils.EnterNativeFullscreen') {
                enterCalls++;
                if (failEnter) {
                  failEnter = false;
                  throw PlatformException(code: 'fullscreen_failed');
                }
              }
              return null;
            },
          );

      try {
        final owner = claimFullScreenOwner();
        await expectLater(
          enterDesktopFullScreen(owner: owner),
          throwsA(isA<PlatformException>()),
        );
        await enterDesktopFullScreen(owner: owner);
        expect(enterCalls, 2);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
