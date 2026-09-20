# Flutter OHOS embedding patch set

This directory owns the direct Flutter OHOS embedding changes used by the
PiliPlusX HCPP build path.  The base checkout remains the pinned OHOS Flutter
commit `aa76d9bbeee7806a87dbd202d2550dfd11550b82`.

`ohos_hcpp_embedding.patch` is the production ArkTS/type patch.  It is applied
by `scripts/prepare_ohos_embedding.py` before the embedding HAR is built.

`ohos_hcpp_native.patch` records the NAPI source change separately.  It is not
applied by the normal HAP path until a matching `libflutter.so` build is
available and its source/ABI contract has been verified.  Applying this source
patch without rebuilding the native engine would create a false provenance
claim.

`ohos_hcpp_embedding_test.patch` contains embedding test changes and is opt-in
for test preparation; it is not part of the production HAP input.

Do not add generated `.ohos` trees, legacy `src/main/` copies, HAR files, or
`.codex-*` backups here.  Those are build outputs or forensic rollback
material, not source patches.
