import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/utils/fullscreen_request_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FullScreenRequest request(bool status) => FullScreenRequest(
    status: status,
    inAppFullScreen: false,
    orientation: null,
    isManualFS: true,
  );

  test(
    'serially executes the latest target queued during a transition',
    () async {
      final queue = FullScreenRequestQueue();
      final gate = Completer<bool>();
      final executed = <bool>[];
      var current = false;

      final first = queue.enqueue(
        request(true),
        isAlive: () => true,
        isAtTarget: (target) => current == target,
        execute: (item) {
          executed.add(item.status);
          if (executed.length == 1) return gate.future;
          return Future<bool>.value(true);
        },
        commit: (target) => current = target,
      );
      final latest = queue.enqueue(
        request(false),
        isAlive: () => true,
        isAtTarget: (target) => current == target,
        execute: (item) {
          executed.add(item.status);
          return Future<bool>.value(true);
        },
        commit: (target) => current = target,
      );

      gate.complete(true);
      await Future.wait([first, latest]);

      expect(executed, [true, false]);
      expect(current, isFalse);
    },
  );

  test(
    'cancels queued platform steps when the page is destroyed while awaiting',
    () async {
      final queue = FullScreenRequestQueue();
      final gate = Completer<bool>();
      final executed = <bool>[];
      var alive = true;
      var committed = false;

      final completion = queue.enqueue(
        request(true),
        isAlive: () => alive,
        isAtTarget: (_) => false,
        execute: (item) {
          executed.add(item.status);
          return gate.future;
        },
        commit: (_) => committed = true,
      );
      queue.enqueue(
        request(false),
        isAlive: () => alive,
        isAtTarget: (_) => false,
        execute: (item) {
          executed.add(item.status);
          return Future<bool>.value(true);
        },
        commit: (_) => committed = true,
      );

      alive = false;
      queue.cancel();
      gate.complete(true);
      await completion;

      expect(executed, [true]);
      expect(committed, isFalse);
      expect(queue.isProcessing, isFalse);
    },
  );

  test(
    'keeps logical state uncommitted after a partial platform failure',
    () async {
      final queue = FullScreenRequestQueue();
      final gate = Completer<bool>();
      final executed = <bool>[];
      var current = false;
      var needsReconciliation = false;

      final completion = queue.enqueue(
        request(true),
        isAlive: () => true,
        isAtTarget: (target) => !needsReconciliation && current == target,
        execute: (item) {
          executed.add(item.status);
          if (item.status) {
            needsReconciliation = true;
            return gate.future;
          }
          return Future<bool>.value(true);
        },
        commit: (target) {
          current = target;
          needsReconciliation = false;
        },
      );
      queue.enqueue(
        request(false),
        isAlive: () => true,
        isAtTarget: (target) => !needsReconciliation && current == target,
        execute: (item) {
          executed.add(item.status);
          return Future<bool>.value(true);
        },
        commit: (target) {
          current = target;
          needsReconciliation = false;
        },
      );

      gate.complete(false);
      await completion;

      expect(executed, [true, false]);
      expect(current, isFalse);
      expect(needsReconciliation, isFalse);
    },
  );
}
