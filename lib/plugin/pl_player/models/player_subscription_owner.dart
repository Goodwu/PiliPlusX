import 'dart:async';

/// Owns stream subscriptions as they are created, including partial setup.
class PlayerSubscriptionOwner {
  final List<StreamSubscription<dynamic>> subscriptions = [];

  StreamSubscription<T> track<T>(StreamSubscription<T> subscription) {
    subscriptions.add(subscription);
    return subscription;
  }

  void cancel() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    subscriptions.clear();
  }
}
