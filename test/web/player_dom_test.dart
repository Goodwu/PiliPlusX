@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:piliplus/main_web.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  testWidgets('web player preserves its DOM and releases media on dispose', (
    tester,
  ) async {
    try {
      final registry = _RecordingViewRegistry();
      ui_web.debugOverridePlatformViewRegistry(registry);
      addTearDown(() => ui_web.debugOverridePlatformViewRegistry(null));

      await tester.pumpWidget(const PiliPlusWebApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'initial web view');

      expect(registry.viewType, 'piliplus-sdr-video');
      expect(find.byType(HtmlElementView), findsOneWidget);
      final video = registry.video!;
      expect(video.controls, isTrue);
      expect(video.getAttribute('playsinline'), 'true');
      expect(video.style.width, '100%');
      expect(video.style.height, '100%');

      // Record browser API calls without decoding media or making a network request.
      var loads = 0;
      var plays = 0;
      var pauses = 0;
      video
        ..setProperty('load'.toJS, (() => loads++).toJS)
        ..setProperty(
          'play'.toJS,
          (() {
            plays++;
            return Future<JSAny?>.value(null).toJS;
          }).toJS,
        )
        ..setProperty('pause'.toJS, (() => pauses++).toJS);

      await tester.tap(find.text('播放'));
      await tester.pump();
      expect(loads, 0);
      expect(plays, 0);

      const source = 'data:video/mp4;base64,';
      await tester.enterText(find.byType(TextField), '  $source  ');
      await tester.tap(find.text('播放'));
      await tester.pump();

      expect(video.getAttribute('src'), source);
      expect(loads, 1);
      expect(plays, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(pauses, 1);
      expect(video.getAttribute('src'), '');
      expect(tester.takeException(), isNull);
    } catch (error, stack) {
      printOnFailure('Web DOM regression: $error\n$stack');
      rethrow;
    }
  });
}

class _RecordingViewRegistry extends ui_web.PlatformViewRegistry {
  String? viewType;
  web.HTMLVideoElement? video;

  @override
  bool registerViewFactory(
    String viewType,
    Function viewFactory, {
    bool isVisible = true,
  }) {
    this.viewType = viewType;
    // Widget tests mock platform-view creation. Inspect the production factory's
    // DOM element directly; this does not assert engine mounting or presentation.
    video = viewFactory(0) as web.HTMLVideoElement;
    return super.registerViewFactory(
      viewType,
      viewFactory,
      isVisible: isVisible,
    );
  }
}
