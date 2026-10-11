"""Exact-source, isolated iOS variant and lifecycle contracts."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP / 'scripts'))
import prepare_ios_variant as ios
import prepare_routing_ci as bootstrap_tools
from verify_routing_sources import PACKAGES


class IOSVariantTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.runner = self.root / 'runner'
        self.runner.mkdir()
        self.source = self.root / 'app'
        self.media = self.root / 'media-kit'
        self.cache = self.runner / 'p'
        self.sdk = self.runner / 'f'
        self.source.mkdir()
        self.cache.mkdir()
        self.init_sdk()
        self.target = self.runner / 'ios/app'
        self.receipt = {'commands': []}
        self._real_command = ios.command
        self.patch_bytes = (APP / ios.PATCH_RELATIVE).read_bytes()
        self.target_files = {name: (APP / name).read_bytes() for name in ios.TRANSFORMED}
        for name, data in self.target_files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        patch_path = self.source / ios.PATCH_RELATIVE
        patch_path.parent.mkdir(parents=True, exist_ok=True)
        patch_path.write_bytes(self.patch_bytes)
        sdk_patch_path = self.source / bootstrap_tools.IOS_SDK_PATCH
        sdk_patch_path.write_bytes((APP / bootstrap_tools.IOS_SDK_PATCH).read_bytes())
        patch_driver = self.source / 'lib/scripts/patch.ps1'
        patch_driver.write_bytes((APP / 'lib/scripts/patch.ps1').read_bytes())
        (self.source / 'pubspec.yaml').write_text(
            'name: piliplus\nflutter:\n  assets:\n    - assets/\n', encoding='utf-8')
        (self.source / 'pubspec.lock').write_text('packages: {}\n', encoding='utf-8')
        asset = self.source / 'assets/known.json'
        asset.parent.mkdir(parents=True)
        asset.write_text('{}\n', encoding='utf-8')
        (self.source / '.gitignore').write_text('.dart_tool/\n', encoding='utf-8')
        (self.source / '.dart_tool').mkdir()
        self.media.mkdir()
        (self.media / 'README.md').write_text('fixture media source\n', encoding='utf-8')
        self.media_package_roots = {}
        for name, relative in PACKAGES.items():
            package = self.media / relative
            package.mkdir(parents=True)
            self.media_package_roots[name] = package.resolve()
        self.plugin = self.cache / 'plugin-1.0.0'
        swift = self.plugin / 'darwin/example/Package.swift'
        swift.parent.mkdir(parents=True)
        swift.write_text('// fixture\n', encoding='utf-8')
        self.plugin.mkdir(exist_ok=True)
        (self.plugin / 'pubspec.yaml').write_text('name: example\n', encoding='utf-8')
        self.bad_plugin_root = False
        self.extra_pub_file = False
        self.write_package_config(self.source, self.source)

        self.app_sha = self.init_remote(self.source)
        self.media_sha = self.init_remote(self.media)
        app_tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=self.source, text=True).strip()
        media_tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=self.media, text=True).strip()
        toolchain = {'frameworkVersion': '3.47.2'}
        sdk_identity = ios.sdk_patch_identity(self.sdk, self.cache, 'ios', toolchain)
        self.patch_driver = self.source / 'lib/scripts/patch.ps1'
        patch_steps = [{
            'name': f'patch-{mode}', 'command': ['pwsh', '-NoLogo', '-NoProfile', '-File',
                                                 str(self.patch_driver), 'ios', f'-{mode}'],
            'cwd': str(self.source), 'exitCode': 0,
        } for mode in ('SdkOnly', 'PackagesOnly')]
        source_hashes = {'app/lib/scripts/patch.ps1': hashlib.sha256(self.patch_driver.read_bytes()).hexdigest()}
        execution_identity = bootstrap_tools.sdk_patch_execution_identity(
            self.source, 'ios', {'app': self.app_sha, 'appTree': app_tree,
                                 'media-kit': self.media_sha, 'media-kitTree': media_tree},
            sdk_identity, patch_steps)
        semantic_witness = self.fake_ios_witness(self.source, self.sdk, sdk_identity['sdkCommit'])
        self.bootstrap = {
            'scope': 'routing-source-bootstrap', 'platform': 'ios',
            'status': 'prepared-source-only',
            'steps': patch_steps,
            'vector': {'app': self.app_sha, 'appTree': app_tree,
                       'media-kit': self.media_sha, 'media-kitTree': media_tree},
            'flutterRoot': str(self.sdk), 'pubCache': str(self.cache),
            'sdkCommit': sdk_identity['sdkCommit'], 'sdkTree': sdk_identity['sdkTree'],
            'toolchain': toolchain, 'sdkPatchIdentity': sdk_identity,
            'flutterToolsPackages': sdk_identity['toolsPackageRoots'],
            'sourceHashes': source_hashes,
            'sdkPatchExecution': execution_identity,
            'iosSdkSemanticWitness': semantic_witness,
        }
        self.allowed_link = 'ios/Flutter/ephemeral/Packages/.packages/plugin-1.0.0'
        self.resources = [{'kind': 'asset', 'declared': 'assets/', 'path': 'assets/', 'directory': True}]
        self.context_patches = [
            patch.object(ios, 'manifest_identity', return_value={'sdkCommit': self.bootstrap['sdkCommit'], 'parserSha256': 'parser'}),
            patch.object(ios, 'input_context', side_effect=self.input_context),
        ]
        for item in self.context_patches:
            item.start()
            self.addCleanup(item.stop)
        self.semantic_patcher = patch.object(ios, 'ios_sdk_semantic_witness', side_effect=self.fake_ios_witness)
        self.semantic_patcher.start()
        self.addCleanup(self.semantic_patcher.stop)
        self.command_patcher = patch.object(ios, 'command', side_effect=self.command)
        self.command_patcher.start()
        self.addCleanup(self.command_patcher.stop)

    def git(self, argv, cwd):
        subprocess.run(argv, cwd=cwd, check=True, capture_output=True)

    def init_sdk(self):
        self.sdk.mkdir()
        for relative in ('packages/flutter_tools', 'packages/flutter/lib/src/cupertino',
                         'packages/flutter/lib/src/material', 'packages/flutter/lib/src/widgets',
                         'bin/cache/dart-sdk/bin'):
            (self.sdk / relative).mkdir(parents=True, exist_ok=True)
        (self.sdk / '.gitignore').write_text('.dart_tool/\n', encoding='utf-8')
        (self.sdk / 'packages/flutter_tools/pubspec.lock').write_text('packages: {}\n', encoding='utf-8')
        for relative in ('cupertino/route.dart', 'material/scaffold.dart', 'widgets/routes.dart'):
            (self.sdk / 'packages/flutter/lib/src' / relative).write_text('base SDK source\n', encoding='utf-8')
        tools_config = self.sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
        tools_config.parent.mkdir(parents=True, exist_ok=True)
        tools_config.write_text(json.dumps({'packages': [
            {'name': 'flutter_tools', 'rootUri': (self.sdk / 'packages/flutter_tools').as_uri()},
            {'name': 'yaml', 'rootUri': (self.cache / 'yaml').as_uri()},
        ]}), encoding='utf-8')
        (self.cache / 'yaml').mkdir()
        self.git(['git', 'init', '-b', 'fixture'], self.sdk)
        self.git(['git', 'config', 'user.name', 'Fixture'], self.sdk)
        self.git(['git', 'config', 'user.email', 'fixture@example.invalid'], self.sdk)
        self.git(['git', 'add', '.'], self.sdk)
        self.git(['git', 'commit', '-m', 'SDK base'], self.sdk)
        # Model the distinct iOS-only SDK patch output in the disposable fixture.
        for relative in ('cupertino/route.dart', 'material/scaffold.dart', 'widgets/routes.dart'):
            path = self.sdk / 'packages/flutter/lib/src' / relative
            path.write_text('iOS-patched SDK source\n', encoding='utf-8')

    def fake_ios_witness(self, app, sdk, sdk_commit):
        patch_path = Path(app) / bootstrap_tools.IOS_SDK_PATCH
        return {
            'appCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=app, text=True).strip(),
            'sdkCommit': sdk_commit, 'patchPath': bootstrap_tools.IOS_SDK_PATCH,
            'patchSha256': hashlib.sha256(patch_path.read_bytes()).hexdigest(),
            'sdkFiles': {relative: {
                'worktreeSha256': hashlib.sha256((Path(sdk) / relative).read_bytes()).hexdigest(),
            } for relative in bootstrap_tools.IOS_SDK_FILES},
            'reverseCheck': {'exitCode': 0},
        }

    def init_remote(self, root):
        self.git(['git', 'init', '-b', 'routing/MK-ROUTING-20261011'], root)
        self.git(['git', 'config', 'user.name', 'Fixture'], root)
        self.git(['git', 'config', 'user.email', 'fixture@example.invalid'], root)
        self.git(['git', 'add', '.'], root)
        self.git(['git', 'commit', '-m', 'fixture'], root)
        remote = self.root / (root.name + '.git')
        subprocess.run(['git', 'clone', '--bare', str(root), str(remote)], check=True, capture_output=True)
        self.git(['git', 'remote', 'add', 'origin', str(remote)], root)
        return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()

    def write_package_config(self, root, app_root):
        config = root / '.dart_tool/package_config.json'
        config.parent.mkdir(parents=True, exist_ok=True)
        packages = [{'name': 'piliplus', 'rootUri': app_root.resolve().as_uri(), 'packageUri': 'lib/'}]
        for name, package in self.media_package_roots.items():
            packages.append({'name': name, 'rootUri': package.as_uri(), 'packageUri': 'lib/'})
        packages.append({'name': 'example', 'rootUri': self.plugin.resolve().as_uri(), 'packageUri': 'lib/'})
        if self.bad_plugin_root:
            packages[-1]['rootUri'] = self.cache.as_uri()
        config.write_text(json.dumps({'configVersion': 2, 'packages': packages}), encoding='utf-8')

    def input_context(self, root, media, sdk, cache, parser, receipt):
        roots = ios.roots(root, media, sdk, cache)
        return {
            'packageRoots': roots, 'resources': self.resources,
            'allowedLinks': {self.allowed_link: {'packageName': 'example', 'canonicalTarget': str(self.plugin / 'darwin/example')}},
            'packageManifestHashes': {'piliplus': 'app-manifest', 'example': 'plugin-manifest'},
        }

    def command(self, argv, cwd, receipt):
        step = {'argv': argv, 'cwd': str(cwd), 'exitCode': 0}
        receipt.setdefault('commands', []).append(step)
        if argv and argv[0] == str(self.sdk / 'bin/flutter'):
            self.write_package_config(Path(cwd), Path(cwd))
            (Path(cwd) / '.flutter-plugins').write_text('fixture\n', encoding='utf-8')
            link = Path(cwd) / self.allowed_link
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(self.plugin / 'darwin/example', target_is_directory=True)
            if self.extra_pub_file:
                (Path(cwd) / 'ios/Runner/unexpected.m').parent.mkdir(parents=True, exist_ok=True)
                (Path(cwd) / 'ios/Runner/unexpected.m').write_text('untracked\n', encoding='utf-8')
            return b'offline locked fixture\n'
        return self._real_command(argv, cwd, receipt)

    def prepare(self):
        with patch.dict(os.environ, {'RUNNER_TEMP': str(self.runner), 'FLUTTER_ROOT': str(self.sdk), 'PUB_CACHE': str(self.cache)}):
            ios.prepare(self.source, self.media, self.target, self.app_sha, self.media_sha,
                        self.receipt, self.bootstrap, manifest_parser=self.source / 'fake-parser.dart')

    def prebuild(self):
        self.bootstrap['status'] = 'fresh-source-only'
        self.bootstrap['finalVector'] = self.bootstrap['vector']
        with patch.dict(os.environ, {'RUNNER_TEMP': str(self.runner), 'FLUTTER_ROOT': str(self.sdk), 'PUB_CACHE': str(self.cache)}):
            ios.finalize(self.source, self.media, self.target, self.app_sha, self.media_sha,
                         self.receipt, self.bootstrap, prebuild=True,
                         manifest_parser=self.source / 'fake-parser.dart')

    def finalize(self):
        self.bootstrap['status'] = 'fresh-source-only'
        self.bootstrap['finalVector'] = self.bootstrap['vector']
        with patch.dict(os.environ, {'RUNNER_TEMP': str(self.runner), 'FLUTTER_ROOT': str(self.sdk), 'PUB_CACHE': str(self.cache)}):
            ios.finalize(self.source, self.media, self.target, self.app_sha, self.media_sha,
                         self.receipt, self.bootstrap, manifest_parser=self.source / 'fake-parser.dart')

    def test_prepare_transforms_exact_two_blobs_and_records_roots_resources_and_links(self):
        self.prepare()
        self.assertEqual(self.receipt['status'], 'prepared')
        self.assertEqual(set(self.receipt['transforms']), set(ios.TRANSFORMED))
        self.assertEqual(set(self.receipt['inputContext']['resources'][0]), {'kind', 'declared', 'path', 'directory'})
        self.assertEqual(set(self.receipt['sourceFiles']['pubLinks']), {self.allowed_link})
        self.assertIn('.flutter-plugins', self.receipt['sourceFiles']['pubGenerated'])
        self.assertEqual(set(self.receipt['vectorBefore']), {'app', 'appTree', 'media-kit', 'media-kitTree'})
        self.assertEqual(self.receipt['vectorBefore'], self.receipt['vectorAfter'])
        for name, original in self.target_files.items():
            self.assertEqual((self.source / name).read_bytes(), original)
            self.assertNotEqual((self.target / name).read_bytes(), original)
        for name in self.receipt['beforeHashes']:
            if name not in ios.TRANSFORMED:
                self.assertEqual((self.target / name).read_bytes(), (self.source / name).read_bytes())
        self.prebuild()
        self.finalize()
        self.assertEqual(self.receipt['status'], 'finalized')
        self.assertEqual(self.receipt['vectorFinal'], self.receipt['vectorBefore'])

    def test_wrong_patch_hash_rejected(self):
        file = self.source / ios.PATCH_RELATIVE
        file.write_bytes(file.read_bytes() + b'\n')
        self.git(['git', 'add', ios.PATCH_RELATIVE], self.source)
        self.git(['git', 'commit', '-m', 'bad patch'], self.source)
        self.app_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.source, text=True).strip()
        subprocess.run(['git', 'push', 'origin', 'HEAD:routing/MK-ROUTING-20261011'], cwd=self.source, check=True, capture_output=True)
        self.bootstrap['vector']['app'] = self.app_sha
        self.receipt = {'commands': []}
        with self.assertRaisesRegex(ios.GateError, 'patch SHA-256 mismatch|source-bound'):
            self.prepare()

    def test_exact_hash_with_wrong_hunk_context_fails_before_pubget(self):
        file = self.source / ios.TRANSFORMED[0]
        file.write_bytes(file.read_bytes().replace(
            b'show HorizontalDragGestureRecognizer;', b'show AnotherRecognizer;', 1))
        self.git(['git', 'add', ios.TRANSFORMED[0]], self.source)
        self.git(['git', 'commit', '-m', 'bad context'], self.source)
        self.app_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.source, text=True).strip()
        subprocess.run(['git', 'push', 'origin', 'HEAD:routing/MK-ROUTING-20261011'], cwd=self.source, check=True, capture_output=True)
        self.bootstrap['vector']['app'] = self.app_sha
        self.receipt = {'commands': []}
        with self.assertRaisesRegex(ios.GateError, 'patch|hunk|context|source Git blob'):
            self.prepare()
        self.assertFalse(any(call['argv'][0] == str(self.sdk / 'bin/flutter') for call in self.receipt['commands']))

    def test_untracked_declared_resource_is_rejected(self):
        self.resources = [{'kind': 'asset', 'declared': 'assets/missing.json', 'path': 'assets/missing.json', 'directory': False}]
        with self.assertRaisesRegex(ios.GateError, 'declared resource is not a tracked input'):
            self.prepare()

    def test_external_package_root_change_is_rejected(self):
        self.bad_plugin_root = True
        with self.assertRaises((ValueError, ios.GateError)):
            self.prepare()

    def test_bootstrap_sdk_outside_runner_private_root_is_rejected(self):
        outside = self.root / 'outside-sdk'
        outside.mkdir()
        self.bootstrap['flutterRoot'] = str(outside)
        with self.assertRaisesRegex(ios.GateError, 'private under RUNNER_TEMP'):
            self.prepare()

    def test_old_receipt_replay_against_another_variant_path_is_rejected(self):
        self.prepare()
        replay = self.runner / 'ios/replayed'
        with self.assertRaisesRegex(ios.GateError, 'identity mismatch'):
            ios.finalize(self.source, self.media, replay, self.app_sha, self.media_sha,
                         self.receipt, self.bootstrap, prebuild=True,
                         manifest_parser=self.source / 'fake-parser.dart')

    def test_prebuild_or_finalized_variant_byte_tamper_is_rejected(self):
        self.prepare()
        (self.target / ios.TRANSFORMED[0]).write_bytes(b'altered after preparation')
        with self.assertRaisesRegex(ios.GateError, 'tracked source bytes changed'):
            self.prebuild()

    def test_finalization_rechecks_variant_after_prebuild(self):
        self.prepare()
        self.prebuild()
        (self.target / ios.TRANSFORMED[1]).write_bytes(b'altered after prebuild')
        with self.assertRaisesRegex(ios.GateError, 'tracked source bytes changed'):
            self.finalize()

    def test_finalization_rechecks_actual_private_sdk_patch_identity(self):
        self.prepare()
        self.prebuild()
        path = self.sdk / 'packages/flutter/lib/src/cupertino/route.dart'
        path.write_bytes(path.read_bytes() + b'changed after bootstrap\n')
        with self.assertRaisesRegex(ios.GateError, 'private SDK/cache identity changed'):
            self.finalize()

    def test_source_advance_after_prepare_is_rejected_before_prebuild(self):
        self.prepare()
        (self.source / 'pubspec.yaml').write_bytes((self.source / 'pubspec.yaml').read_bytes() + b'# new source\n')
        self.git(['git', 'add', 'pubspec.yaml'], self.source)
        self.git(['git', 'commit', '-m', 'advance'], self.source)
        subprocess.run(['git', 'push', 'origin', 'HEAD:routing/MK-ROUTING-20261011'],
                       cwd=self.source, check=True, capture_output=True)
        with self.assertRaisesRegex(ios.GateError, 'final app vector'):
            self.prebuild()

    def test_extra_generated_native_input_is_rejected_during_prepare(self):
        self.extra_pub_file = True
        with self.assertRaisesRegex(ios.GateError, 'unknown source/build input'):
            self.prepare()

    def test_patch_script_keeps_legacy_full_ios_app_patch_but_excludes_variant_phases(self):
        script = (APP / 'lib/scripts/patch.ps1').read_text(encoding='utf-8')
        self.assertIn('if (-not $SdkOnly -and -not $PackagesOnly -and $platform.ToLower() -eq "ios")', script)
        self.assertIn('if ($SdkOnly) {', script)
        self.assertIn('if (-not $PackagesOnly) {', script)
        self.assertIn('$patches_material += $BottomSheetIOSFlutterMaterialPatchMaterial', script)
        self.assertIn('$patches_cupertino += $BottomSheetIOSFlutterPatchCupertino', script)

    def test_ios_bootstrap_requires_successful_source_bound_phase_commands(self):
        self.bootstrap['steps'][0]['command'][-2] = 'android'
        with self.assertRaisesRegex(ios.GateError, 'source-bound SDK patch execution'):
            self.prepare()

    def test_ios_bootstrap_requires_private_cwd_and_zero_phase_exit(self):
        self.bootstrap['steps'][1]['cwd'] = str(self.source.parent)
        with self.assertRaisesRegex(ios.GateError, 'source-bound SDK patch execution'):
            self.prepare()

    def test_ios_bootstrap_rejects_nonzero_patch_phase(self):
        self.bootstrap['steps'][1]['exitCode'] = 9
        with self.assertRaisesRegex(ios.GateError, 'source-bound SDK patch execution'):
            self.prepare()

    def test_in_process_outer_finalize_step_append_does_not_mutate_bound_snapshot(self):
        self.prepare()
        self.receipt = json.loads(json.dumps(self.receipt))
        self.bootstrap = json.loads(json.dumps(self.bootstrap))
        self.bootstrap['status'] = 'fresh-source-only'
        self.bootstrap['finalVector'] = self.bootstrap['vector']
        self.bootstrap['steps'].append({'name': 'finalized-source-vector', 'exitCode': 0})
        self.prebuild()
        self.finalize()
        self.assertEqual(self.receipt['status'], 'finalized')

    def test_android_bootstrap_platform_is_rejected(self):
        self.bootstrap['platform'] = 'android'
        with self.assertRaisesRegex(ios.GateError, 'iOS routing-source-bootstrap'):
            self.prepare()

    def test_missing_bootstrap_platform_is_rejected(self):
        self.bootstrap.pop('platform')
        with self.assertRaisesRegex(ios.GateError, 'iOS routing-source-bootstrap'):
            self.prepare()

    def test_wrong_bootstrap_scope_is_rejected(self):
        self.bootstrap['scope'] = 'routing-android-bootstrap'
        with self.assertRaisesRegex(ios.GateError, 'iOS routing-source-bootstrap'):
            self.prepare()

    def assert_final_gate_rejects_bootstrap_identity_edit(self, key, value, *, remove=False):
        self.prepare()
        if remove:
            self.bootstrap.pop(key)
        else:
            self.bootstrap[key] = value
        with self.assertRaises(ios.GateError):
            self.prebuild()
        self.receipt['prebuildChecked'] = True
        with self.assertRaises(ios.GateError):
            self.finalize()

    def test_final_gate_rejects_android_bootstrap_identity(self):
        self.assert_final_gate_rejects_bootstrap_identity_edit('platform', 'android')

    def test_final_gate_rejects_missing_bootstrap_platform(self):
        self.assert_final_gate_rejects_bootstrap_identity_edit('platform', None, remove=True)

    def test_final_gate_rejects_wrong_bootstrap_scope(self):
        self.assert_final_gate_rejects_bootstrap_identity_edit('scope', 'routing-android-bootstrap')

    def test_final_gate_rejects_two_platform_labels_relabelled_from_android(self):
        self.prepare()
        self.bootstrap['platform'] = 'android'
        self.bootstrap['sdkPatchIdentity']['platform'] = 'android'
        with self.assertRaises(ios.GateError):
            self.prebuild()
        self.receipt['prebuildChecked'] = True
        with self.assertRaises(ios.GateError):
            self.finalize()


class IOSPatchSemanticsTests(unittest.TestCase):
    flutter = APP.parent / '.runtime/flutter'

    def setUp(self):
        if not self.flutter.is_dir():
            self.skipTest('shared Flutter Git source is not present')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = APP
        self.sdk_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.flutter, text=True).strip()

    def sdk_state(self, platform):
        root = self.root / platform
        files = [*bootstrap_tools.IOS_SDK_FILES, 'packages/flutter/lib/src/material/bottom_sheet.dart']
        for relative in files:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(subprocess.check_output(
                ['git', 'cat-file', 'blob', f'HEAD:{relative}'], cwd=self.flutter))
        subprocess.run(['git', 'init', '-b', 'fixture'], cwd=root, check=True, capture_output=True)
        subprocess.run(['git', 'config', 'user.name', 'Fixture'], cwd=root, check=True, capture_output=True)
        subprocess.run(['git', 'config', 'user.email', 'fixture@example.invalid'], cwd=root, check=True, capture_output=True)
        subprocess.run(['git', 'add', '.'], cwd=root, check=True, capture_output=True)
        subprocess.run(['git', 'commit', '-m', 'three-file Flutter input'], cwd=root, check=True, capture_output=True)
        commands = [
            ['git', 'apply', '--include=packages/flutter/lib/src/widgets/routes.dart',
             str(APP / 'lib/scripts/modal_barrier.patch')],
            ['git', 'apply', '--include=packages/flutter/lib/src/material/scaffold.dart',
             str(APP / 'lib/scripts/scaffold.patch')],
        ]
        if platform.startswith('ios'):
            commands.append(['git', 'apply', str(APP / bootstrap_tools.IOS_SDK_PATCH)])
        else:
            commands.append(['git', 'apply', '--include=packages/flutter/lib/src/material/bottom_sheet.dart',
                             str(APP / 'lib/scripts/bottom_sheet_android.patch')])
        for command in commands:
            subprocess.run(command, cwd=root, check=True, capture_output=True)
        return root

    def test_real_three_file_ios_chain_passes_and_android_only_chain_fails(self):
        ios_sdk = self.sdk_state('ios')
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ios_sdk, text=True).strip()
        witness = bootstrap_tools.ios_sdk_semantic_witness(self.app, ios_sdk, commit)
        self.assertEqual(witness['patchSha256'], bootstrap_tools.IOS_SDK_PATCH_SHA256)
        self.assertEqual(set(witness['sdkFiles']), set(bootstrap_tools.IOS_SDK_FILES))
        self.assertTrue(all(item['headBlobSha1'] and item['headBlobSha256'] and item['worktreeSha256']
                            for item in witness['sdkFiles'].values()))
        self.assertEqual(witness['reverseCheck']['exitCode'], 0)

        android_sdk = self.sdk_state('android')
        android_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=android_sdk, text=True).strip()
        with self.assertRaisesRegex(ValueError, 'reverse patch check failed'):
            bootstrap_tools.ios_sdk_semantic_witness(self.app, android_sdk, android_commit)

        tampered = self.sdk_state('ios-tampered')
        route = tampered / bootstrap_tools.IOS_SDK_FILES[0]
        route.write_bytes(route.read_bytes().replace(
            b'_HorizontalDragGestureRecognizer', b'_BrokenHorizontalDragRecognizer', 1))
        tampered_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=tampered, text=True).strip()
        with self.assertRaisesRegex(ValueError, 'reverse patch check failed'):
            bootstrap_tools.ios_sdk_semantic_witness(self.app, tampered, tampered_commit)

    def test_semantic_gate_rejects_source_patch_mutation_and_reverse_tool_failure(self):
        ios_sdk = self.sdk_state('ios')
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ios_sdk, text=True).strip()
        bad_app = self.root / 'bad-app'
        patch_path = bad_app / bootstrap_tools.IOS_SDK_PATCH
        patch_path.parent.mkdir(parents=True)
        patch_path.write_bytes((APP / bootstrap_tools.IOS_SDK_PATCH).read_bytes() + b'\n')
        subprocess.run(['git', 'init', '-b', 'fixture'], cwd=bad_app, check=True, capture_output=True)
        subprocess.run(['git', 'config', 'user.name', 'Fixture'], cwd=bad_app, check=True, capture_output=True)
        subprocess.run(['git', 'config', 'user.email', 'fixture@example.invalid'], cwd=bad_app, check=True, capture_output=True)
        subprocess.run(['git', 'add', '.'], cwd=bad_app, check=True, capture_output=True)
        subprocess.run(['git', 'commit', '-m', 'tampered patch'], cwd=bad_app, check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, 'patch differs from its exact source Git blob|SHA-256'):
            bootstrap_tools.ios_sdk_semantic_witness(bad_app, ios_sdk, commit)

        real_run = subprocess.run
        def fail_reverse(argv, *args, **kwargs):
            if argv[:4] == ['git', 'apply', '--reverse', '--check']:
                return subprocess.CompletedProcess(argv, 19, b'', b'forced reverse failure')
            return real_run(argv, *args, **kwargs)
        with patch.object(bootstrap_tools.subprocess, 'run', side_effect=fail_reverse):
            with self.assertRaisesRegex(ValueError, r'reverse patch check failed \(19\)'):
                bootstrap_tools.ios_sdk_semantic_witness(self.app, ios_sdk, commit)


if __name__ == '__main__':
    unittest.main()
