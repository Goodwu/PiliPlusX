import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/models/player_subscription_owner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancels subscriptions already registered before a later listen fails',
    () async {
      final source = StreamController<int>.broadcast(sync: true);
      final owner = PlayerSubscriptionOwner()
        ..track(source.stream.listen((_) {}));

      expect(
        () => owner.track(_ThrowingListenStream().listen((_) {})),
        throwsA(isA<StateError>()),
      );
      owner.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(source.hasListener, isFalse);
      expect(owner.subscriptions, isEmpty);
      await source.close();
    },
  );
}

class _ThrowingListenStream extends Stream<int> {
  @override
  StreamSubscription<int> listen(
    void Function(int event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    throw StateError('listener registration failed');
  }
}
