import 'package:piliplus/common/widgets/flutter/chat_list_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _list(ScrollController controller, int count) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(
      width: 320,
      height: 120,
      child: ChatListView.separated(
        maxExtent: 320,
        controller: controller,
        padding: EdgeInsets.zero,
        itemCount: count,
        itemBuilder: (_, index) => SizedBox(
          key: ValueKey('message-$index'),
          height: 40,
          child: Text('message-$index'),
        ),
        separatorBuilder: (_, _) => const SizedBox(height: 4),
      ),
    ),
  ),
);

void main() {
  testWidgets('empty and short chat lists keep finite layout offsets', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(controller, 0));
    expect(tester.takeException(), isNull);
    expect(controller.position.maxScrollExtent, 0);

    await tester.pumpWidget(_list(controller, 2));
    expect(tester.takeException(), isNull);
    expect(find.text('message-0'), findsOneWidget);
    expect(find.text('message-1'), findsOneWidget);
    expect(controller.position.maxScrollExtent, 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('message-0'))).dy.isFinite,
        isTrue);
    expect(tester.getSize(find.byKey(const ValueKey('message-0'))).height, 40);
  });

  testWidgets('chat list lays out both scroll ends and can shrink after scrolling', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_list(controller, 20));
    expect(controller.position.maxScrollExtent, greaterThan(0));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('message-19'), findsOneWidget);

    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('message-0'), findsOneWidget);

    await tester.pumpWidget(_list(controller, 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(controller.position.maxScrollExtent, 0);
    expect(find.text('message-0'), findsOneWidget);
  });
}
