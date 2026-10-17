import 'dart:ui' show SemanticsAction, Tristate;

import 'package:piliplus/common/widgets/flutter/text_field/controller.dart';
import 'package:piliplus/common/widgets/flutter/text_field/cupertino/text_field.dart';
import 'package:piliplus/common/widgets/flutter/text_field/editable_text.dart'
    as rich;
import 'package:piliplus/common/widgets/flutter/text_field/text_field.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _CustomHandles extends MaterialTextSelectionControls {
  int builds = 0;

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) {
    builds++;
    return GestureDetector(
      onTap: onTap,
      child: const SizedBox(
        key: ValueKey('custom-selection-handle'),
        width: 24,
        height: 24,
        child: ColoredBox(color: Colors.blue),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String clipboard = '';
  int clipboardWrites = 0;

  setUp(() {
    clipboard = 'paste';
    clipboardWrites = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String;
              clipboardWrites++;
              return null;
            case 'Clipboard.getData':
              return <String, dynamic>{'text': clipboard};
            case 'Clipboard.hasStrings':
              return <String, dynamic>{'value': clipboard.isNotEmpty};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  void editingTest(
    String description,
    WidgetTesterCallback callback, {
    Set<TargetPlatform> platforms = const {TargetPlatform.android},
  }) {
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant(platforms),
    );
  }

  Future<({RichTextEditingController controller, rich.EditableTextState state})>
  mount(
    WidgetTester tester, {
    bool readOnly = false,
    bool obscureText = false,
    bool cupertino = false,
    bool interactiveSelection = true,
    TextSelectionControls? controls,
    rich.EditableTextContextMenuBuilder? menuBuilder,
    FocusNode? focusNode,
    ValueChanged<String>? onChanged,
    List<RichTextItem>? items,
    VoidCallback? onMention,
  }) async {
    final controller = RichTextEditingController(
      items: items ?? [RichTextItem.fromStart('hello world')],
      onMention: onMention,
    );
    final focus = focusNode ?? FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: cupertino
                  ? CupertinoRichTextField(
                      controller: controller,
                      focusNode: focus,
                      readOnly: readOnly,
                      obscureText: obscureText,
                      enableInteractiveSelection: interactiveSelection,
                      selectionControls: controls,
                      onChanged: onChanged,
                    )
                  : menuBuilder != null
                  ? RichTextField(
                      controller: controller,
                      focusNode: focus,
                      selectionControls: controls,
                      contextMenuBuilder: menuBuilder,
                    )
                  : RichTextField(
                      controller: controller,
                      focusNode: focus,
                      readOnly: readOnly,
                      obscureText: obscureText,
                      enableInteractiveSelection: interactiveSelection,
                      selectionControls: controls,
                      onChanged: onChanged,
                      // Preserve the actual default builder when no custom
                      // builder is supplied.
                    ),
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      if (focusNode == null) focus.dispose();
    });
    focus.requestFocus();
    await tester.pump();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    final state = tester.state<rich.EditableTextState>(
      find.byType(rich.EditableText),
    );
    await state.clipboardStatus.update();
    await tester.pump();
    return (controller: controller, state: state);
  }

  Set<ContextMenuButtonType> types(rich.EditableTextState state) =>
      state.contextMenuButtonItems.map((item) => item.type).toSet();

  void press(rich.EditableTextState state, ContextMenuButtonType type) => state
      .contextMenuButtonItems
      .singleWhere((item) => item.type == type)
      .onPressed!();

  for (final cupertino in [false, true]) {
    editingTest(
      '${cupertino ? 'Cupertino' : 'Material'} default menu edits rich text',
      (tester) async {
        final field = await mount(tester, cupertino: cupertino);
        expect(
          field.state.widget.selectionControls,
          isA<TextSelectionHandleControls>(),
        );
        expect(
          types(field.state),
          containsAll([
            ContextMenuButtonType.copy,
            ContextMenuButtonType.cut,
            ContextMenuButtonType.paste,
            ContextMenuButtonType.selectAll,
          ]),
        );
        expect(field.state.showToolbar(), isTrue);
        await tester.pump();
        expect(find.text('Copy'), findsOneWidget);
        await tester.tap(find.text('Copy'));
        await tester.pump();
        expect(clipboard, 'hello');
        expect(clipboardWrites, 1);
        expect(field.controller.text, 'hello world');

        field.controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 5,
        );
        await tester.pump();
        press(field.state, ContextMenuButtonType.cut);
        await tester.pump();
        expect(clipboardWrites, 2);
        expect(field.controller.text, ' world');
        expect(field.controller.plainText, ' world');
        expect(
          field.controller.selection,
          const TextSelection.collapsed(offset: 0),
        );

        clipboard = 'new';
        press(field.state, ContextMenuButtonType.paste);
        await tester.pump();
        expect(field.controller.text, 'new world');
        expect(field.controller.plainText, 'new world');
        press(field.state, ContextMenuButtonType.selectAll);
        await tester.pump();
        expect(
          field.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: 9),
        );
      },
    );
  }

  for (final scenario in [
    (
      readOnly: true,
      obscure: false,
      copy: true,
      cut: false,
      paste: false,
      select: true,
    ),
    (
      readOnly: false,
      obscure: true,
      copy: false,
      cut: false,
      paste: true,
      select: true,
    ),
    (
      readOnly: true,
      obscure: true,
      copy: false,
      cut: false,
      paste: false,
      select: false,
    ),
  ]) {
    editingTest(
      'menu protects readOnly=${scenario.readOnly} obscure=${scenario.obscure}',
      (tester) async {
        final field = await mount(
          tester,
          readOnly: scenario.readOnly,
          obscureText: scenario.obscure,
        );
        final menu = types(field.state);
        expect(menu.contains(ContextMenuButtonType.copy), scenario.copy);
        expect(menu.contains(ContextMenuButtonType.cut), scenario.cut);
        expect(menu.contains(ContextMenuButtonType.paste), scenario.paste);
        expect(menu.contains(ContextMenuButtonType.selectAll), scenario.select);
        field.state.cutSelection(SelectionChangedCause.toolbar);
        field.state.copySelection(SelectionChangedCause.toolbar);
        if (scenario.readOnly) {
          await field.state.pasteText(SelectionChangedCause.toolbar);
          expect(field.controller.text, 'hello world');
        }
        if (scenario.obscure) expect(clipboardWrites, 0);
      },
    );
  }

  editingTest('rich mentions survive copy and synchronize on cut and paste', (
    tester,
  ) async {
    int mentions = 0;
    final field = await mount(
      tester,
      onMention: () => mentions++,
      items: [
        RichTextItem.fromStart('@Alice', type: RichTextType.at, id: '42'),
        RichTextItem(text: ' world', range: const TextRange(start: 6, end: 12)),
      ],
    );
    field.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await tester.pump();
    press(field.state, ContextMenuButtonType.copy);
    await tester.pump();
    expect(clipboard, '@Alice');
    expect(field.controller.items.first.type, RichTextType.at);
    expect(field.controller.items.first.id, '42');
    field.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 6,
    );
    await tester.pump();
    press(field.state, ContextMenuButtonType.cut);
    await tester.pump();
    expect(field.controller.text, ' world');
    expect(field.controller.plainText, ' world');
    expect(
      field.controller.items.every((item) => item.type != RichTextType.at),
      isTrue,
    );
    clipboard = '@';
    press(field.state, ContextMenuButtonType.paste);
    await tester.pump();
    expect(mentions, 1);
    expect(field.controller.text, '@ world');
    expect(field.controller.plainText, '@ world');
  });

  editingTest('keyboard copy cut paste and select-all remain functional', (
    tester,
  ) async {
    final field = await mount(tester);
    Future<void> shortcut(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await shortcut(LogicalKeyboardKey.keyC);
    expect(clipboard, 'hello');
    await shortcut(LogicalKeyboardKey.keyX);
    expect(field.controller.text, ' world');
    clipboard = 'typed';
    await shortcut(LogicalKeyboardKey.keyV);
    expect(field.controller.text, 'typed world');
    expect(field.controller.plainText, 'typed world');
    await shortcut(LogicalKeyboardKey.keyA);
    expect(
      field.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 11),
    );
  });

  editingTest('read-only password shortcuts do not copy cut or paste', (
    tester,
  ) async {
    final field = await mount(tester, readOnly: true, obscureText: true);
    for (final key in [
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyV,
    ]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(field.controller.text, 'hello world');
    expect(clipboardWrites, 0);
  });

  editingTest('semantics exposes focused editing actions and cuts once', (
    tester,
  ) async {
    final custom = _CustomHandles();
    final field = await mount(tester, controls: custom);
    final node = tester.getSemantics(find.byType(rich.EditableText));
    expect(node.getSemanticsData().hasAction(SemanticsAction.copy), isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.cut), isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.paste), isTrue);
    field.state.renderEditable.owner!.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.copy,
    );
    await tester.pump();
    expect(clipboard, 'hello');
    expect(clipboardWrites, 1);
    clipboardWrites = 0;
    field.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 5,
    );
    await tester.pump();
    field.state.renderEditable.owner!.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.cut,
    );
    await tester.pump();
    expect(clipboard, 'hello');
    expect(clipboardWrites, 1);
    expect(field.controller.text, ' world');
    expect(field.controller.plainText, ' world');
  }, platforms: {TargetPlatform.android, TargetPlatform.macOS});

  editingTest('disabled interactive selection disables keyboard edits', (
    tester,
  ) async {
    final field = await mount(tester, interactiveSelection: false);
    for (final key in [
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyV,
    ]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(field.controller.text, 'hello world');
    expect(clipboardWrites, 0);
  });

  editingTest('custom controls keep handles and use the modern custom menu', (
    tester,
  ) async {
    final controls = _CustomHandles();
    final field = await mount(
      tester,
      controls: controls,
      menuBuilder: (context, state) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: [
          ...state.contextMenuButtonItems.where(
            (item) => item.type == ContextMenuButtonType.copy,
          ),
          ContextMenuButtonItem(label: 'Custom action', onPressed: () {}),
        ],
      ),
    );
    expect(controls, isNot(isA<TextSelectionHandleControls>()));
    field.state.userUpdateTextEditingValue(
      field.controller.value.copyWith(
        selection: const TextSelection(baseOffset: 0, extentOffset: 4),
      ),
      SelectionChangedCause.longPress,
    );
    await tester.pump();
    expect(field.state.showToolbar(), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Custom action'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(controls.builds, greaterThan(0));
    final handles = find.byKey(const ValueKey('custom-selection-handle'));
    expect(handles, findsWidgets);
    final priorSelection = field.controller.selection;
    await tester.drag(handles.first, const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(field.controller.selection, isNot(priorSelection));
    expect(field.controller.selection.isValid, isTrue);
    expect(find.text('Custom action'), findsOneWidget);
  });

  editingTest('default menu also works with non-marker custom handles', (
    tester,
  ) async {
    final field = await mount(tester, controls: _CustomHandles());
    field.state.showToolbar();
    await tester.pump();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboard, 'hello');
    expect(clipboardWrites, 1);
  });

  editingTest(
    'empty clipboard removes paste and focus semantics stay explicit',
    (tester) async {
      clipboard = '';
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final field = await mount(tester, focusNode: focus);
      expect(types(field.state), isNot(contains(ContextMenuButtonType.paste)));
      var data = tester
          .getSemantics(find.byType(rich.EditableText))
          .getSemanticsData();
      expect(data.flagsCollection.isFocused, Tristate.isTrue);
      expect(data.hasAction(SemanticsAction.copy), isTrue);
      focus.unfocus();
      await tester.pump();
      data = tester
          .getSemantics(find.byType(rich.EditableText))
          .getSemanticsData();
      expect(data.flagsCollection.isFocused, Tristate.isFalse);
      expect(data.hasAction(SemanticsAction.copy), isFalse);
      expect(data.hasAction(SemanticsAction.cut), isFalse);
    },
  );

  editingTest('cursor alpha and ticker pause resume preserve focus', (
    tester,
  ) async {
    final controller = RichTextEditingController(
      items: [RichTextItem.fromStart('cursor')],
    );
    final focus = FocusNode();
    final key = GlobalKey<rich.EditableTextState>();
    Future<void> render(bool ticking) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TickerMode(
            enabled: ticking,
            child: rich.EditableText(
              key: key,
              controller: controller,
              focusNode: focus,
              style: const TextStyle(fontSize: 16),
              cursorColor: const Color.from(
                alpha: 0.4999,
                red: 0.2,
                green: 0.4,
                blue: 0.6,
              ),
              backgroundCursorColor: Colors.grey,
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
    await render(true);
    focus.requestFocus();
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    expect(
      key.currentState!.renderEditable.cursorColor!.a,
      closeTo(0.4999, 0.000001),
    );
    expect(key.currentState!.cursorCurrentlyVisible, isTrue);
    await render(false);
    await tester.pump(const Duration(seconds: 2));
    expect(key.currentState!.cursorCurrentlyVisible, isFalse);
    expect(focus.hasFocus, isTrue);
    await render(true);
    await tester.pump();
    expect(key.currentState!.cursorCurrentlyVisible, isTrue);
    expect(
      key.currentState!.renderEditable.cursorColor!.a,
      closeTo(0.4999, 0.000001),
    );
  });
}
