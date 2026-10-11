import 'dart:ui' show Tristate;

import 'package:piliplus/common/widgets/flutter/list_tile.dart' as app;
import 'package:piliplus/common/widgets/flutter/vertical_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

void main() {
  testWidgets('ListTile background checks retain 8-bit alpha quantization', (
    tester,
  ) async {
    final reports = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    var reportsAfterZeroAlpha = -1;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ListTile background color')) {
        reports.add(details);
      } else if (previousOnError != null) {
        previousOnError(details);
      } else {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    Widget buildTile(double alpha) => mui.MaterialApp(
      home: mui.Material(
        child: ColoredBox(
          color: Colors.white,
          child: app.ListTile(
            title: const Text('Tile'),
            tileColor: Color.from(alpha: alpha, red: 0, green: 0, blue: 0),
          ),
        ),
      ),
    );

    try {
      await tester.pumpWidget(buildTile(0.001));
      reportsAfterZeroAlpha = reports.length;
      await tester.pumpWidget(buildTile(0.002));
    } finally {
      // Restore the test binding handler before assertions so captured
      // diagnostics cannot be mistaken for unhandled test errors.
      FlutterError.onError = previousOnError;
    }
    expect(
      reportsAfterZeroAlpha,
      0,
      reason: 'alpha below half of one 8-bit step quantizes to zero',
    );
    expect(
      reports.where(
        (details) =>
            details.exceptionAsString().contains('ListTile background color'),
      ),
      hasLength(1),
      reason: 'alpha above half of one 8-bit step quantizes to one',
    );
  });

  testWidgets('VerticalSlider semantics retain interactive focusability', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final focusManager = FocusManager.instance;
    final previousHighlightStrategy = focusManager.highlightStrategy;
    focusManager.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() {
      focusManager.highlightStrategy = previousHighlightStrategy;
    });
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    Widget buildSlider({required bool enabled}) => mui.MaterialApp(
      home: mui.Scaffold(
        body: SizedBox(
          width: 100,
          height: 300,
          child: VerticalSlider(
            value: 0.5,
            label: 'Volume',
            focusNode: focusNode,
            onChanged: enabled ? (_) {} : null,
          ),
        ),
      ),
    );

    try {
      await tester.pumpWidget(buildSlider(enabled: true));
      final interactiveData = tester.getSemantics(
        find.bySemanticsLabel('Volume'),
      );
      expect(
        interactiveData.flagsCollection.isFocused,
        Tristate.isFalse,
      );

      focusNode.requestFocus();
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Volume'))
            .flagsCollection
            .isFocused,
        Tristate.isTrue,
      );

      await tester.pumpWidget(buildSlider(enabled: false));
      final disabledData = tester.getSemantics(
        find.bySemanticsLabel('Volume'),
      );
      expect(disabledData.flagsCollection.isFocused, Tristate.none);
    } finally {
      semantics.dispose();
    }
  });
}
