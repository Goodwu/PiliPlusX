#!/usr/bin/env python3
"""Prepare/recheck a private, source-bound iOS App copy; never modify source."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from prepare_android_variant import (
    GateError,
    command,
    digest,
    input_context,
    manifest_identity,
    roots,
    source_files,
    tracked_bytes,
)
from prepare_routing_ci import (
    BRANCH,
    ios_sdk_semantic_witness,
    sdk_patch_execution_identity,
    sdk_patch_identity,
)

PATCH_RELATIVE = 'lib/scripts/bottom_sheet_ios_piliplus.patch'
PATCH_SHA256 = '77133bbc48b74500fd15b3e50e86a7b96dff0876fce1ef949d1ebe9cab3a2e05'
INPUT_BLOBS = {
    'lib/pages/common/slide/common_slide_page.dart': '4f71516e17757da7c2889d2e3992999efa2104be',
    'lib/common/widgets/scaffold/mini_scaffold.dart': '077520c0ccf214f08630c25dfe2c310acdb43727',
}
TRANSFORMED = tuple(INPUT_BLOBS)


def git_blob_sha(data: bytes) -> str:
    header = f'blob {len(data)}\0'.encode('ascii')
    return hashlib.sha1(header + data).hexdigest()


def source_vector(source: Path, media: Path, expected_app: str, expected_media: str,
                  receipt: dict, phase: str) -> dict[str, str]:
    vector: dict[str, str] = {}
    for name, root, expected in (('app', source, expected_app), ('media-kit', media, expected_media)):
        head = command(['git', 'rev-parse', 'HEAD'], root, receipt).decode().strip()
        remote = command(['git', 'ls-remote', '--exit-code', 'origin', BRANCH], root, receipt).decode().splitlines()
        if head != expected or len(remote) != 1 or remote[0].split() != [expected, BRANCH]:
            raise GateError(f'{phase} {name} vector differs from the exact remote source')
        vector[name] = head
        vector[name + 'Tree'] = command(['git', 'rev-parse', 'HEAD^{tree}'], root, receipt).decode().strip()
    return vector


def copy_tracked(files: dict[str, tuple[bytes, str]], target: Path) -> None:
    for name, (data, mode) in files.items():
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if mode == '100755' else 0o644)


def verify_patch(source: Path, target: Path, files: dict[str, tuple[bytes, str]], receipt: dict) -> dict[str, bytes]:
    patch = source / PATCH_RELATIVE
    if not patch.is_file() or patch.is_symlink():
        raise GateError('pinned iOS App patch is missing or not a regular file')
    data = patch.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    receipt['iosAppPatch'] = {'path': PATCH_RELATIVE, 'sha256': actual, 'expectedSha256': PATCH_SHA256}
    if actual != PATCH_SHA256:
        raise GateError('pinned iOS App patch SHA-256 mismatch')
    if any(name not in files for name in TRANSFORMED):
        raise GateError('pinned iOS patch target missing from exact source blobs')
    for name, expected_blob in INPUT_BLOBS.items():
        if git_blob_sha(files[name][0]) != expected_blob:
            raise GateError('pinned iOS patch source Git blob differs: ' + name)
    expected = patch_outputs(source, files, receipt)
    command(['git', 'apply', '--check', str(patch)], target, receipt)
    command(['git', 'apply', str(patch)], target, receipt)
    changed = []
    transformed = {}
    for name, (original, _) in files.items():
        result = (target / name).read_bytes()
        if result != original:
            changed.append(name)
            transformed[name] = result
    if tuple(sorted(changed)) != tuple(sorted(TRANSFORMED)):
        raise GateError('iOS patch changed an unexpected tracked input set')
    if set(transformed) != set(TRANSFORMED) or any(transformed[name] == files[name][0] for name in TRANSFORMED):
        raise GateError('iOS patch did not produce both expected App transforms')
    if transformed != expected:
        raise GateError('iOS patch output differs from independently applied pinned patch')
    receipt['transforms'] = {
        name: {'beforeSha256': digest(files[name][0]), 'afterSha256': digest(transformed[name])}
        for name in TRANSFORMED
    }
    return transformed


def patch_outputs(source: Path, files: dict[str, tuple[bytes, str]], receipt: dict) -> dict[str, bytes]:
    patch = source / PATCH_RELATIVE
    if not patch.is_file() or patch.is_symlink() or hashlib.sha256(patch.read_bytes()).hexdigest() != PATCH_SHA256:
        raise GateError('pinned iOS App patch SHA-256 mismatch')
    if any(name not in files or git_blob_sha(files[name][0]) != blob for name, blob in INPUT_BLOBS.items()):
        raise GateError('pinned iOS patch source Git blob differs from reviewed input')
    with tempfile.TemporaryDirectory(prefix='routing-ios-patch-') as temporary:
        root = Path(temporary)
        for name in TRANSFORMED:
            if name not in files:
                raise GateError('pinned iOS patch target missing from exact source blobs')
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(files[name][0])
        try:
            command(['git', 'apply', '--check', str(patch)], root, receipt)
        except RuntimeError as error:
            raise GateError('pinned iOS patch context does not match exact source blobs') from error
        command(['git', 'apply', str(patch)], root, receipt)
        outputs = {name: (root / name).read_bytes() for name in TRANSFORMED}
    if any(outputs[name] == files[name][0] for name in TRANSFORMED):
        raise GateError('pinned iOS patch did not transform both expected files')
    return outputs


def private_paths(bootstrap: dict, source: Path, media: Path) -> tuple[Path, Path]:
    runner_temp = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    sdk = Path(bootstrap['flutterRoot']).resolve()
    cache = Path(bootstrap['pubCache']).resolve()
    if not sdk.is_dir() or not cache.is_dir():
        raise GateError('iOS variant private SDK/cache is missing')
    for label, path in (('SDK', sdk), ('PUB_CACHE', cache)):
        if not path.is_relative_to(runner_temp) or path == runner_temp:
            raise GateError(f'iOS variant {label} must remain private under RUNNER_TEMP')
        if any(path.is_relative_to(root) or root.is_relative_to(path)
               for root in (source.resolve(), media.resolve())):
            raise GateError(f'iOS variant {label} may not overlap source checkouts')
    if sdk == cache or sdk.is_relative_to(cache) or cache.is_relative_to(sdk):
        raise GateError('iOS private SDK and PUB_CACHE roots must be separate')
    return sdk, cache


def assert_private_environment(bootstrap: dict, source: Path, media: Path) -> tuple[Path, Path]:
    sdk, cache = private_paths(bootstrap, source, media)
    if Path(os.environ.get('FLUTTER_ROOT', '')).resolve() != sdk or Path(os.environ.get('PUB_CACHE', '')).resolve() != cache:
        raise GateError('iOS variant must use the bootstrap private SDK/cache')
    if not sdk.is_dir() or not cache.is_dir():
        raise GateError('iOS variant private SDK/cache is missing')
    return sdk, cache


def bind_bootstrap(bootstrap: dict, source: Path, sdk: Path, cache: Path,
                   expected_vector: dict[str, str]) -> dict:
    if (bootstrap.get('scope') != 'routing-source-bootstrap'
            or bootstrap.get('platform') != 'ios'
            or bootstrap.get('status') != 'prepared-source-only'
            or {key: bootstrap.get('vector', {}).get(key) for key in expected_vector} != expected_vector):
        raise GateError('iOS variant requires an iOS routing-source-bootstrap receipt for the exact source vector')
    toolchain = bootstrap.get('toolchain')
    expected_sdk = bootstrap.get('sdkPatchIdentity')
    if not isinstance(toolchain, dict) or not isinstance(expected_sdk, dict):
        raise GateError('iOS bootstrap is missing its private SDK patch identity')
    try:
        actual_sdk = sdk_patch_identity(sdk, cache, 'ios', toolchain)
    except (OSError, ValueError) as error:
        raise GateError(f'iOS bootstrap private SDK identity cannot be verified: {error}') from error
    if (expected_sdk != actual_sdk or bootstrap.get('sdkCommit') != actual_sdk['sdkCommit']
            or bootstrap.get('sdkTree') != actual_sdk['sdkTree']
            or bootstrap.get('flutterRoot') != str(sdk) or bootstrap.get('pubCache') != str(cache)
            or bootstrap.get('flutterToolsPackages') != actual_sdk['toolsPackageRoots']):
        raise GateError('iOS bootstrap private SDK/cache identity differs from its actual platform-patched state')
    try:
        actual_execution = sdk_patch_execution_identity(
            source, 'ios', bootstrap['vector'], actual_sdk, bootstrap.get('steps', []))
        actual_witness = ios_sdk_semantic_witness(source, sdk, actual_sdk['sdkCommit'])
    except (OSError, ValueError) as error:
        raise GateError(f'iOS source-bound SDK patch execution cannot be verified: {error}') from error
    if (actual_execution != bootstrap.get('sdkPatchExecution')
            or actual_witness != bootstrap.get('iosSdkSemanticWitness')
            or bootstrap.get('sourceHashes', {}).get('app/lib/scripts/patch.ps1')
            != actual_execution.get('scriptSha256')):
        raise GateError('iOS source-bound successful SDK/Packages patch phases or semantic patch witness differ')
    stable_receipt = {key: value for key, value in bootstrap.items()
                      if key not in ('status', 'finalVector', 'steps')}
    identity = {
        'scope': bootstrap['scope'], 'platform': bootstrap['platform'],
        'status': bootstrap['status'], 'vector': bootstrap['vector'],
        'flutterRoot': bootstrap['flutterRoot'], 'pubCache': bootstrap['pubCache'],
        'sdkCommit': bootstrap['sdkCommit'], 'sdkTree': bootstrap['sdkTree'],
        'flutterToolsPackages': bootstrap['flutterToolsPackages'],
        'toolchain': toolchain, 'sdkPatchIdentity': actual_sdk,
        'sdkPatchExecution': actual_execution, 'iosSdkSemanticWitness': actual_witness,
        'outerStableSha256': hashlib.sha256(json.dumps(
            stable_receipt, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
        'outerPreparedSteps': copy.deepcopy(bootstrap.get('steps', [])),
    }
    identity['sha256'] = hashlib.sha256(json.dumps(
        identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return identity


def verify_bootstrap_identity(identity: dict, bootstrap: dict, source: Path, sdk: Path, cache: Path,
                              expected_vector: dict[str, str], *, final: bool) -> None:
    allowed_status = {'fresh-source-only'} if final else {'prepared-source-only', 'fresh-source-only'}
    if (identity.get('scope') != 'routing-source-bootstrap' or identity.get('platform') != 'ios'
            or identity.get('status') != 'prepared-source-only'
            or bootstrap.get('scope') != 'routing-source-bootstrap'
            or bootstrap.get('platform') != 'ios'
            or bootstrap.get('status') not in allowed_status
            or {key: bootstrap.get('vector', {}).get(key) for key in expected_vector} != expected_vector
            or bootstrap.get('vector') != identity.get('vector')
            or bootstrap.get('flutterRoot') != str(sdk) or bootstrap.get('pubCache') != str(cache)):
        raise GateError('iOS variant receipt is not bound to an iOS source bootstrap')
    stable_fields = ('sdkCommit', 'sdkTree', 'flutterToolsPackages', 'toolchain',
                     'sdkPatchIdentity', 'sdkPatchExecution', 'iosSdkSemanticWitness')
    if any(bootstrap.get(key) != identity.get(key) for key in stable_fields):
        raise GateError('iOS bootstrap stable SDK/toolchain identity changed during lifecycle')
    if bootstrap['status'] == 'fresh-source-only' and bootstrap.get('finalVector') != identity.get('vector'):
        raise GateError('iOS source bootstrap final vector does not match its prepared vector')
    stable_receipt = {key: value for key, value in bootstrap.items()
                      if key not in ('status', 'finalVector', 'steps')}
    stable_digest = hashlib.sha256(json.dumps(
        stable_receipt, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    prepared_steps = identity.get('outerPreparedSteps')
    current_steps = bootstrap.get('steps')
    if (stable_digest != identity.get('outerStableSha256') or not isinstance(prepared_steps, list)
            or not isinstance(current_steps, list) or current_steps[:len(prepared_steps)] != prepared_steps):
        raise GateError('iOS source bootstrap changed outside its reviewed finalize lifecycle')
    stored = dict(identity)
    claimed_hash = stored.pop('sha256', None)
    actual_hash = hashlib.sha256(json.dumps(
        stored, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if claimed_hash != actual_hash:
        raise GateError('iOS bootstrap identity receipt hash mismatch')
    try:
        actual_sdk = sdk_patch_identity(sdk, cache, 'ios', identity.get('toolchain'))
        actual_execution = sdk_patch_execution_identity(
            source, 'ios', bootstrap['vector'], actual_sdk, bootstrap.get('steps', []))
        actual_witness = ios_sdk_semantic_witness(source, sdk, actual_sdk['sdkCommit'])
    except (OSError, ValueError) as error:
        raise GateError(f'iOS final gate cannot verify private SDK identity: {error}') from error
    if (identity.get('sdkPatchIdentity') != actual_sdk
            or identity.get('sdkCommit') != actual_sdk['sdkCommit']
            or identity.get('sdkTree') != actual_sdk['sdkTree']
            or identity.get('flutterToolsPackages') != actual_sdk['toolsPackageRoots']
            or bootstrap.get('sdkPatchExecution') != actual_execution
            or identity.get('sdkPatchExecution') != actual_execution
            or bootstrap.get('iosSdkSemanticWitness') != actual_witness
            or identity.get('iosSdkSemanticWitness') != actual_witness
            or bootstrap.get('sourceHashes', {}).get('app/lib/scripts/patch.ps1')
            != actual_execution.get('scriptSha256')):
        raise GateError('iOS final gate private SDK/cache identity changed')


def prepare(source: Path, media: Path, target: Path, expected_app: str, expected_media: str,
            receipt: dict, bootstrap: dict, *, manifest_parser: Path | None = None) -> None:
    receipt.update(scope='routing-ios-variant', status='failed', stage='source',
                   appCommit=expected_app, mediaKitCommit=expected_media, commands=[])
    expected_vector = {'app': expected_app, 'media-kit': expected_media}
    sdk, cache = assert_private_environment(bootstrap, source, media)
    identity = bind_bootstrap(bootstrap, source, sdk, cache, expected_vector)
    receipt['vectorBefore'] = source_vector(source, media, expected_app, expected_media, receipt, 'before')
    files = tracked_bytes(source, expected_app, receipt)
    parser = manifest_parser or source / 'android/tool/parse_routing_manifest.dart'
    receipt['manifestParser'] = manifest_identity(source, {name: data for name, (data, _) in files.items()},
                                                   sdk, cache, parser, receipt, bootstrap)
    before_context = input_context(source, media, sdk, cache, parser, receipt)
    source_inventory = source_files(source, {name: data for name, (data, _) in files.items()}, 'source',
                                    resources=before_context['resources'],
                                    allowed_links=before_context['allowedLinks'])
    runner_temp = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    parent = target.absolute().parent
    if (parent.exists() or not parent.resolve().is_relative_to(runner_temp)
            or parent.resolve() == runner_temp):
        raise GateError('iOS variant requires a fresh private workspace under RUNNER_TEMP')
    for root in (sdk, cache):
        if target.resolve().is_relative_to(root) or root.is_relative_to(target.resolve()):
            raise GateError('iOS variant workspace may not overlap the private SDK/cache')
    for ancestor in parent.parents:
        if ancestor.resolve() == runner_temp:
            break
        if ancestor.is_symlink():
            raise GateError('iOS variant parent may not traverse a symlink')
    parent.mkdir(parents=True, mode=0o700)
    target.mkdir()
    (parent / 'media-kit').symlink_to(media.resolve(strict=True), target_is_directory=True)
    receipt['stage'] = 'copy-and-patch-private-app'
    copy_tracked(files, target)
    transformed = verify_patch(source, target, files, receipt)
    before_hashes = {name: digest(data) for name, (data, _) in files.items()}
    after_hashes = {name: digest(transformed.get(name, data)) for name, (data, _) in files.items()}
    if {name for name in before_hashes if before_hashes[name] != after_hashes[name]} != set(TRANSFORMED):
        raise GateError('iOS transform changed more or fewer than its two approved App files')
    receipt.update(beforeHashes=before_hashes, afterHashes=after_hashes,
                   sourceRoot=str(source.resolve()), variantRoot=str(target.resolve()),
                   mediaKitRoot=str(media.resolve()), flutterRoot=str(sdk), pubCache=str(cache))
    before_roots = before_context['packageRoots']
    receipt['stage'] = 'offline-enforced-lock-resolution'
    command([str(sdk / 'bin/flutter'), 'pub', 'get', '--offline', '--enforce-lockfile'], target, receipt)
    after_roots = roots(target, media, sdk, cache)
    expected_roots = dict(before_roots)
    app_names = [name for name, path in before_roots.items() if Path(path) == source.resolve()]
    if app_names != ['piliplus']:
        raise GateError('exactly the piliplus App package root must move into the iOS variant')
    expected_roots['piliplus'] = str(target.resolve())
    if after_roots != expected_roots:
        raise GateError('iOS variant changed a non-App package root')
    for name, (data, _) in files.items():
        expected = transformed.get(name, data)
        if (target / name).read_bytes() != expected:
            raise GateError('offline locked resolution modified tracked iOS variant bytes: ' + name)
    context = input_context(target, media, sdk, cache, parser, receipt)
    if context['packageManifestHashes'] != before_context['packageManifestHashes']:
        raise GateError('iOS variant changed an external package manifest')
    receipt['packageRoots'] = after_roots
    receipt['inputContext'] = context
    receipt['sourceInventory'] = source_inventory
    receipt['bootstrapTools'] = {key: bootstrap[key] for key in ('sdkCommit', 'flutterToolsPackages')}
    receipt['bootstrapIdentity'] = identity
    receipt['sourceFiles'] = source_files(target, {name: transformed.get(name, data) for name, (data, _) in files.items()},
                                         'prebuild', resources=context['resources'],
                                         allowed_links=context['allowedLinks'])
    receipt['vectorAfter'] = source_vector(source, media, expected_app, expected_media, receipt, 'after')
    if receipt['vectorAfter'] != receipt['vectorBefore']:
        raise GateError('App/media-kit source vector changed during iOS variant preparation')
    receipt.update(status='prepared', stage='complete')


def finalize(source: Path, media: Path, target: Path, expected_app: str, expected_media: str,
             receipt: dict, bootstrap: dict, *, prebuild: bool = False,
             manifest_parser: Path | None = None) -> None:
    if (receipt.get('scope') != 'routing-ios-variant' or receipt.get('status') != 'prepared'
            or receipt.get('appCommit') != expected_app or receipt.get('mediaKitCommit') != expected_media
            or receipt.get('sourceRoot') != str(source.resolve()) or receipt.get('mediaKitRoot') != str(media.resolve())
            or receipt.get('variantRoot') != str(target.resolve())):
        raise GateError('iOS variant finalization identity mismatch/unprepared')
    if not prebuild and receipt.get('prebuildChecked') is not True:
        raise GateError('iOS variant requires prebuild source verification before finalization')
    receipt['vectorFinal'] = source_vector(source, media, expected_app, expected_media, receipt, 'final')
    if receipt['vectorFinal'] != receipt.get('vectorBefore') or receipt['vectorFinal'] != receipt.get('vectorAfter'):
        raise GateError('iOS variant final source vector differs from prepared vector')
    files = tracked_bytes(source, expected_app, receipt)
    parser = manifest_parser or source / 'android/tool/parse_routing_manifest.dart'
    expected: dict[str, bytes] = {}
    for name, (data, _) in files.items():
        path = target / name
        if not path.is_file() or path.is_symlink():
            raise GateError('iOS variant tracked input missing or symlink: ' + name)
        expected[name] = path.read_bytes()
        if name not in TRANSFORMED and expected[name] != data:
            raise GateError('iOS variant changed an unapproved tracked input: ' + name)
        if name in TRANSFORMED and digest(data) != receipt.get('beforeHashes', {}).get(name):
            raise GateError('iOS source transform input hash changed: ' + name)
    if {name for name, (data, _) in files.items() if expected[name] != data} != set(TRANSFORMED):
        raise GateError('iOS variant tracked diff no longer contains exactly the two approved files')
    expected_hashes = {name: digest(data) for name, data in expected.items()}
    if expected_hashes != receipt.get('afterHashes'):
        raise GateError('iOS variant tracked source bytes changed after preparation')
    exact_patch_outputs = patch_outputs(source, files, receipt)
    if any(expected[name] != exact_patch_outputs[name] for name in TRANSFORMED):
        raise GateError('iOS variant transformed bytes no longer match the pinned patch output')
    sdk, cache = private_paths({'flutterRoot': receipt['flutterRoot'], 'pubCache': receipt['pubCache']},
                               source, media)
    verify_bootstrap_identity(receipt.get('bootstrapIdentity', {}), bootstrap, source, sdk, cache,
                              {'app': expected_app, 'media-kit': expected_media}, final=not prebuild)
    if bootstrap.get('vector') != receipt.get('vectorBefore'):
        raise GateError('iOS bootstrap source vector differs from the prepared variant vector')
    if (Path(os.environ.get('FLUTTER_ROOT', '')).resolve() != sdk
            or Path(os.environ.get('PUB_CACHE', '')).resolve() != cache):
        raise GateError('iOS prebuild/finalize environment differs from the prepared SDK/cache')
    identity = manifest_identity(source, {name: data for name, (data, _) in files.items()},
                                 sdk, cache, parser, receipt, receipt['bootstrapTools'])
    if identity != receipt.get('manifestParser'):
        raise GateError('iOS manifest parser SDK/tool/config identity changed')
    before_context = input_context(source, media, sdk, cache, parser, receipt)
    source_files(source, {name: data for name, (data, _) in files.items()}, 'source',
                 resources=before_context['resources'], allowed_links=before_context['allowedLinks'])
    context = input_context(target, media, sdk, cache, parser, receipt)
    if context != receipt.get('inputContext'):
        raise GateError('iOS variant YAML resources/plugin links/package closure changed')
    inventory = source_files(target, expected, 'prebuild' if prebuild else 'finalize',
                             resources=context['resources'], allowed_links=context['allowedLinks'])
    baseline = receipt['sourceFiles']
    if (inventory['inputs'] != baseline['inputs'] or inventory['pubGenerated'] != baseline['pubGenerated']
            or inventory['pubLinks'] != baseline['pubLinks']
            or (prebuild and inventory['buildGenerated'] != baseline['buildGenerated'])):
        raise GateError('iOS variant generated/unknown source inputs changed')
    if roots(target, media, sdk, cache) != receipt.get('packageRoots'):
        raise GateError('iOS variant external package roots changed')
    if prebuild:
        receipt['prebuildChecked'] = True
    else:
        receipt['finalGeneratedHashes'] = inventory['buildGenerated']
        receipt.update(status='finalized', stage='complete')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'media-kit-root', 'variant', 'receipt', 'bootstrap'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--app-commit', required=True)
    parser.add_argument('--media-kit-commit', required=True)
    parser.add_argument('--manifest-parser', type=Path, required=True)
    lifecycle = parser.add_mutually_exclusive_group()
    lifecycle.add_argument('--finalize', action='store_true')
    lifecycle.add_argument('--check-prebuild', action='store_true')
    args = parser.parse_args()
    receipt = {'scope': 'routing-ios-variant', 'status': 'failed', 'commands': []}
    try:
        if args.finalize or args.check_prebuild:
            receipt = json.loads(args.receipt.read_text(encoding='utf-8'))
            bootstrap = json.loads(args.bootstrap.read_text(encoding='utf-8'))
            finalize(args.source, args.media_kit_root, args.variant, args.app_commit,
                     args.media_kit_commit, receipt, bootstrap, prebuild=args.check_prebuild,
                     manifest_parser=args.manifest_parser)
        else:
            bootstrap = json.loads(args.bootstrap.read_text(encoding='utf-8'))
            prepare(args.source, args.media_kit_root, args.variant, args.app_commit,
                    args.media_kit_commit, receipt, bootstrap, manifest_parser=args.manifest_parser)
    except Exception as error:
        receipt.update(status='failed', reason=str(error))
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
        print(f"routing iOS variant: failed: {error}")
        return 1
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print(f"routing iOS variant: {receipt['status']}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
