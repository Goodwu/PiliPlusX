# CI and B1/B3 follow-up / MK-ROUTING-20261011

This is a continuation of App PR1 and media-kit PR4 on routing/MK-ROUTING-20261011, not a new implementation. Central plan remains media-kit docs/plans/media-kit-routing-implementation-20261011.md v3. Read the current refs and PR result comments before resuming.

## Already integrated, do not repeat

- App d0926b315af63b43bf5452119b4e4a067f58f88c merges the existing Android7 startup fix30434b3eb into this task, retaining both histories. Integration PR2 is closed by that merge; primary PR1 remains draft.
- media-kit8b80f452 merges existing d7619227. The vkweak release asset is not a fresh source-native build candidate.
- App c6c72369c79d9cbd1310302fe23dc8d03b3bd8b2 supplies required current source refs to ios/mac reusable workflows and adds four contract tests. The old Build now starts real jobs; remaining old locked dependencies/release preflights and full-source APK gates are not declared solved.
- media-kit98a349f7 fixes failed-dependency bypass in the SDR safety fallback and preserves root errors. e4f7af3c makes the formerly bug-preserving second-review test exercise a real reclassification followed by hardware failure. b48d94ce extends the original native harness and records B3 branch ownership. Independent latest-head validation is required.
- Native production repair e8df200cdaba99cc98ba1def82034396d945597b is in **Goodwu/FFmpeg PR1 / routing/MK-ROUTING-20261011**. Do not recreate it. It aligns P8 lookup/configure profile and denies unknown/empty native DV evidence. mpv production code has not been changed.

## Reviewed analyzer cleanup checkpoint

The safe-fix review run38129989761 was based on App ea6ae504 and the then-current media-kit checkout. Artifact11698843234 SHA256 ac50170e8c95cd7ad497f17f8351f7fe9c34f4dc320243e3a13dd4185b34b490 was downloaded and reviewed.

Only five source/test files are accepted: const placement in main_web, self-package import spelling, and unused closure parameter spelling in three tests. The suggested Get.reset tear-off was deliberately NOT accepted, because changing an ignored return value into a teardown return could change asynchronous cleanup semantics. The tool's ancillary pubspec dependency change was also NOT committed. No analyzer configuration or test suppression is added. Consequently the staged analyzer count is not final candidate evidence; independently rerun strict analyze, all App tests, bundle and actual source-binding checks.

Original85 info debt is partially addressed, not complete. Remaining cascade style, copied Flutter deprecated controls, web imports, package naming and async test cleanup require separate review; do not broadly rename or rewrite controls merely to claim success without regression evidence.

## Remaining acceptance

B1 original/unknown source facts, importer and output identity; B3 independent Android compilation and product integration; LG ordinary managed output, advanced configuration and other adapters; full latest-source native mpv/FFmpeg/helper APK and real devices. All task PRs remain draft. Bundle or declared codec support is not native/device/HDR presentation acceptance. Stage work is saved remotely before long validation, and final results must name exact input SHAs and run IDs.
