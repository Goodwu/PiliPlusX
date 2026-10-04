import 'dart:io';
import 'dart:ui' show Locale;

import 'package:PiliPlus/pages/video/local_diagnostic/local_video_diagnostic.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/path_utils.dart' as app_paths;
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory supportDirectory;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'piliplusx-local-diagnostic-intro-',
    );
    app_paths.appSupportDirPath = supportDirectory.path;
    app_paths.tmpDirPath = supportDirectory.path;
    await GStorage.init();
  });

  tearDownAll(() async {
    await GStorage.close();
    await Hive.close();
    await supportDirectory.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  test('Get.put initializes a network-free intro without Bilibili ids', () {
    final intro = Get.put(
      LocalDiagnosticIntroController(
        diagnosticHeroTag: 'local-diagnostic-test',
      ),
      tag: 'local-diagnostic-test',
    );

    expect(
      Get.find<LocalDiagnosticIntroController>(tag: 'local-diagnostic-test'),
      same(intro),
    );
    expect(intro.heroTag, 'local-diagnostic-test');
    expect(intro.videoDetail.value.title, '本地视频诊断');
    expect(intro.hasLater.value, isFalse);
    expect(intro.total.value, '1');
    expect(intro.videoTags.value, isNull);
    expect(intro.isShowOnlineTotal, isFalse);
    expect(intro.timer, isNull);
    expect(intro.prevPlay(), isFalse);
    expect(intro.nextPlay(), isFalse);
  });

  testWidgets('player page stays inert when the compile flag is off', (
    tester,
  ) async {
    await tester.pumpWidget(
      const GetMaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale('en', 'US')],
        home: LocalVideoDiagnosticPlayerPage(),
      ),
    );

    expect(find.text('此入口未在当前 macOS 构建中启用。'), findsOneWidget);
    expect(PlPlayerController.instanceExists(), isFalse);
  });
}
