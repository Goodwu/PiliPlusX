# MK-ROUTING-20261011 App CI evidence

Supporting execution evidence for the single central plan and this branch's App handoff. Do not restart implemented stages on another branch.

## 2c4001fb actual results

Run 38074535394, App source 2c4001fbddf410d9d1dbb829fc1137f34c143748, media-kit ef3951eb239d48747f4cbb2c3c2749fde40ff274.

- macOS Python job114278637022 completed/success: **225 tests, OK, no skips**. Artifact11678137586 was downloaded and its source.txt/tests.log read back.
- App job114278637299 successfully resolved dependencies and verified all ten media-kit package roots use the current sibling checkout. Actual compiler Flutter3.47.2, as required by current App pubspec.
- SDK preparation failed after the repository's existing patches were applied: `OHOS Flutter pointer filter source drift in custom scrollable.dart`. Flutter analyze/test and bundle were blocked before execution, not passed.
- Actual source-resolution receipt explicitly records nativeBinaryProvenanceVerified=false and deviceTest=false. No full native App acceptance.

## Narrow pointer-patch repair

The current scrollable_gesture.patch adds a horizontalDragGestureRecognizer constructor argument. The later pointer-filter patch expects hitTestBehavior to be the final argument, so the two existing patches fail to compose. Preserve both horizontal behavior and the vertical pointer filter: recognize only the two reviewed constructor shapes, insert pointerDownFilter without deleting existing arguments, and still reject unknown/duplicate/partial shapes.

The current prepare_ohos_flutter.py was recovered from the remote text and its Git blob checked as d652f9fbc5d52e59333d3f069c3f801bbf909ccb before editing. Six targeted Python tests were run against that old script: five passed and the prior-horizontal-patch case reproduced the same source-drift error. After the narrow repair all six passed; the eight package-root tests were also rerun and passed. These are source-transform tests on bounded fixtures, not SDK compilation or gesture/device acceptance.

The repair and regression tests are committed together. The existing read-only workflow must now rerun the real App patch/test/bundle process on the new head. A later failure does not erase this completed repair; extend it only with concrete new evidence.

## Still open

Full App Flutter test/bundle execution, complete latest-source native APK/App build, final B2 query/predict/report integration, devices and the old Build workflow startup failure. The legacy Build caller still has older reusable-workflow/ref contracts and pinned release checks; it is not disabled or counted as green.
