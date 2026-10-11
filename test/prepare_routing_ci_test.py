"""Failure/ownership tests for source bootstrap using real package-config fixtures."""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('prepare_routing_ci', SCRIPTS / 'prepare_routing_ci.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app, self.media = self.root / 'app', self.root / 'media-kit'
        self.temp = self.root / 'runner-temp'
        self.private = self.temp / 'job'
        for path in (self.app / 'lib', self.app / 'test', self.media, self.private):
            path.mkdir(parents=True)
        (self.app / 'pubspec.yaml').write_text('environment:\n  flutter: 3.47.2\n')
        (self.app / 'lib/main.dart').write_text('business source\n')
        (self.app / 'test/example.dart').write_text('test source\n')
        (self.media / 'README.md').write_text('library source\n')
        for relative in module.verify.__globals__['PACKAGES'].values():
            (self.media / relative).mkdir(parents=True, exist_ok=True)
        self.sdk = self.private / 'flutter'
        self.sdk_fixture(self.sdk)
        self.app_sha, self.media_sha = 'a' * 40, 'b' * 40
        self.args = argparse.Namespace(app_root=self.app, media_kit_root=self.media, flutter_root=self.sdk,
                                       private_root=self.private, output=self.private / 'results',
                                       expected_app_sha=self.app_sha, expected_media_kit_sha=self.media_sha,
                                       platform='linux', finalize=False)
        self.failure = None
        self.remote_drift = False
        self.sdk_dirty = False
        self.escape_tools = False
        self.escape_app = False
        self.rewrite_source = False
        self.dirty_input = False
        self.toolchain_version = '3.47.2'
        self.real_run = subprocess.run
        self.real_untracked_git = False
        self.real_sdk_git = False
        self.sdk_diff_failure = False
        self.calls = []
        self.environ = patch.dict(os.environ, {'RUNNER_TEMP': str(self.temp)}, clear=False)
        self.environ.start()
        self.addCleanup(self.environ.stop)
        self.process = patch.object(module.subprocess, 'run', side_effect=self.command)
        self.process.start()
        self.addCleanup(self.process.stop)

    def sdk_fixture(self, root):
        for relative in ('.git', 'packages/flutter_tools', 'packages/flutter', 'bin/cache/dart-sdk/bin'):
            (root / relative).mkdir(parents=True, exist_ok=True)
        for relative in ('bin/flutter', 'bin/flutter.bat', 'bin/cache/dart-sdk/bin/dart', 'bin/cache/dart-sdk/bin/dart.exe'):
            (root / relative).write_text('executable fixture\n')

    def config(self, path, packages):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'packages': [{'name': name, 'rootUri': root.as_uri()} for name, root in packages.items()]}))

    def command(self, command, *, cwd, env, **kwargs):
        self.calls.append((command, Path(cwd), dict(env)))
        stdout, code = '', 0
        if command[0] == 'git' and self.real_sdk_git and Path(cwd) == self.sdk:
            if self.sdk_diff_failure and command[1:] == ['diff', '--binary']:
                return subprocess.CompletedProcess(command, 7, 'diff reader failure', '')
            return self.real_run(command, cwd=cwd, env=env, **kwargs)
        if command[0] == 'git':
            args = command[1:]
            if args == ['rev-parse', '--show-toplevel']:
                stdout = str(cwd)
            elif args == ['rev-parse', 'HEAD']:
                stdout = self.app_sha if cwd == self.app else self.media_sha
            elif args == ['rev-parse', 'HEAD^{tree}']:
                stdout = 'c' * 40
            elif args == ['diff', '--exit-code', 'HEAD', '--'] and self.dirty_input:
                code, stdout = 1, 'unknown source diff\n'
            elif args[:1] == ['ls-remote']:
                expected = self.app_sha if cwd == self.app else self.media_sha
                stdout = ('f' * 40 if self.remote_drift else expected) + '\t' + module.BRANCH
            elif args[:1] == ['status']:
                stdout = ' M unknown.dart' if self.sdk_dirty else ''
            elif args[:1] == ['ls-files'] and '--others' in args:
                if self.real_untracked_git:
                    return self.real_run(command, cwd=cwd, env=env, **kwargs)
            elif args[:1] == ['ls-files']:
                stdout = 'lib/main.dart\0test/example.dart\0' if cwd == self.app else 'README.md\0'
        elif command[0].endswith(('dart', 'dart.exe')):
            sdk = Path(env['FLUTTER_ROOT'])
            target = self.root / 'old-tools' if self.escape_tools else sdk / 'packages/flutter_tools'
            target.mkdir(exist_ok=True)
            self.config(sdk / 'packages/flutter_tools/.dart_tool/package_config.json', {'flutter_tools': target})
        elif len(command) > 2 and command[1:3] == ['pub', 'get']:
            packages = {name: self.media / relative for name, relative in module.verify.__globals__['PACKAGES'].items()}
            cache_package = Path(env['PUB_CACHE']) / 'hosted/example'
            cache_package.mkdir(parents=True, exist_ok=True)
            packages.update(piliplus=self.app, example=cache_package)
            if self.escape_app:
                shared = self.root / 'shared-package'
                shared.mkdir()
                packages['example'] = shared
            self.config(self.app / '.dart_tool/package_config.json', packages)
        elif command[1:] == ['--version', '--machine']:
            stdout = json.dumps({'frameworkVersion': self.toolchain_version})
        elif command[0] == 'pwsh':
            if self.failure == command[-1]:
                code, stdout = 23, 'patch failed\n'
            if self.rewrite_source:
                (self.app / 'lib/main.dart').write_text('unauthorized rewrite\n')
        if not kwargs.get('text'):
            return subprocess.CompletedProcess(command, code, stdout.encode(), b'')
        return subprocess.CompletedProcess(command, code, stdout)

    def bootstrap(self):
        return module.Bootstrap(self.args)

    def test_prepare_and_final_check_bind_sources_and_private_environment(self):
        bootstrap = self.bootstrap()
        bootstrap.prepare()
        receipt = json.loads((self.args.output / 'bootstrap.json').read_text())
        self.assertEqual(receipt['status'], 'prepared-source-only')
        self.assertFalse(receipt['nativeBinaryProvenanceVerified'])
        self.assertEqual([call[0][-1] for call in self.calls if call[0][0] == 'pwsh'], ['-SdkOnly', '-PackagesOnly'])
        for command, cwd, env in self.calls:
            if command[0] != 'git':
                self.assertTrue(Path(env['FLUTTER_ROOT']).is_relative_to(self.private))
                self.assertTrue(Path(env['PUB_CACHE']).is_relative_to(self.private))
        self.bootstrap().finalize()
        receipt = json.loads((self.args.output / 'bootstrap.json').read_text())
        self.assertEqual(receipt['status'], 'fresh-source-only')
        self.assertFalse(receipt['deviceTest'])

    def test_patch_failure_retains_exit_code_and_stops_next_patch(self):
        self.failure = '-SdkOnly'
        with self.assertRaisesRegex(RuntimeError, 'exit code 23'):
            self.bootstrap().prepare()
        receipt = json.loads((self.args.output / 'bootstrap.json').read_text())
        self.assertEqual(receipt['steps'][-1]['exitCode'], 23)
        self.assertEqual(len([call for call in self.calls if call[0][0] == 'pwsh']), 1)

    def test_remote_drift_stops_before_toolchain_mutation(self):
        self.remote_drift = True
        with self.assertRaisesRegex(ValueError, 'source vector drift'):
            self.bootstrap().prepare()
        self.assertTrue(all(call[0][0] == 'git' for call in self.calls))

    def test_dirty_input_rejected_before_sdk_or_dependency_mutation(self):
        self.dirty_input = True
        with self.assertRaisesRegex(RuntimeError, 'clean-input failed'):
            self.bootstrap().prepare()
        self.assertTrue(all(call[0][0] == 'git' for call in self.calls))
        self.assertEqual((self.app / 'lib/main.dart').read_text(), 'business source\n')

    def test_receipt_outside_private_root_rejected_without_writing(self):
        self.args.output = self.root / 'outside-results'
        with self.assertRaisesRegex(ValueError, 'children of RUNNER_TEMP'):
            self.bootstrap()
        self.assertFalse(self.args.output.exists())

    def test_wrong_toolchain_rejected_before_app_resolution(self):
        self.toolchain_version = '3.47.7'
        with self.assertRaisesRegex(ValueError, 'exact App pubspec contract'):
            self.bootstrap().prepare()
        self.assertFalse(any(call[0][0] == 'pwsh' for call in self.calls))
        self.assertFalse((self.app / '.dart_tool/package_config.json').exists())

    def real_source_repositories(self, ignored=''):
        self.real_untracked_git = True
        for root in (self.app, self.media):
            self.real_run(['git', 'init', str(root)], check=True, capture_output=True)
            (root / '.gitignore').write_text('.dart_tool/\n**/__pycache__/\n' + ignored)
            self.real_run(['git', '-C', str(root), 'add', '--force', '.'], check=True, capture_output=True)

    def test_real_untracked_test_rejected_without_removal(self):
        self.real_source_repositories()
        unexpected = self.app / 'test/untracked_test.dart'
        unexpected.write_text('unknown test source')
        with self.assertRaisesRegex(ValueError, 'Untracked app input'):
            self.bootstrap().prepare()
        self.assertEqual(unexpected.read_text(), 'unknown test source')
        self.assertFalse(any(call[0][0] == 'pwsh' for call in self.calls))

    def test_real_ignored_test_is_still_rejected(self):
        self.real_source_repositories('test*\n')
        unexpected = self.app / 'test/untracked_test.dart'
        unexpected.write_text('ignored unknown test source')
        with self.assertRaisesRegex(ValueError, 'Untracked ignored app source input'):
            self.bootstrap().prepare()
        self.assertTrue(unexpected.exists())

    def test_real_untracked_library_source_is_rejected(self):
        self.real_source_repositories()
        unexpected = self.media / 'media_kit/lib/new_source.dart'
        unexpected.parent.mkdir(parents=True)
        unexpected.write_text('unknown library source')
        with self.assertRaisesRegex(ValueError, 'Untracked media-kit input'):
            self.bootstrap().prepare()
        self.assertTrue(unexpected.exists())

    def test_real_ignored_library_source_is_rejected(self):
        self.real_source_repositories('*.dart\n')
        unexpected = self.media / 'media_kit/lib/new_source.dart'
        unexpected.parent.mkdir(parents=True)
        unexpected.write_text('ignored library source')
        with self.assertRaisesRegex(ValueError, 'Untracked ignored media-kit source input'):
            self.bootstrap().prepare()
        self.assertTrue(unexpected.exists())

    def test_only_python_bytecode_cache_is_permitted_in_source_domain(self):
        self.real_source_repositories()
        cache = self.app / 'test/__pycache__/generated.cpython-313.pyc'
        cache.parent.mkdir()
        cache.write_bytes(b'bytecode fixture')
        self.bootstrap().prepare()
        source = cache.parent / 'untracked.py'
        source.write_text('this is still source')
        with self.assertRaisesRegex(ValueError, 'Untracked ignored app source input'):
            self.bootstrap().finalize()

    def test_protected_github_workspace_not_exported(self):
        env_file = self.private / 'github-env'
        with patch.dict(os.environ, {'GITHUB_ENV': str(env_file)}):
            self.bootstrap().prepare()
        exported = env_file.read_text()
        self.assertNotIn('GITHUB_WORKSPACE=', exported)
        self.assertIn(f'ROUTING_APP_ROOT={self.app}', exported)
        for command, _, env in self.calls:
            if command[0] == 'pwsh':
                self.assertEqual(env['GITHUB_WORKSPACE'], str(self.app))

    def test_crlf_patch_input_rejected_without_normalizing_source(self):
        patch_file = self.app / 'lib/scripts/material/example.patch'
        patch_file.parent.mkdir(parents=True)
        original = b'patch line\r\n'
        patch_file.write_bytes(original)
        with self.assertRaisesRegex(ValueError, 'LF checkout'):
            self.bootstrap().prepare()
        self.assertEqual(patch_file.read_bytes(), original)
        self.assertFalse(any(call[0][0] == 'pwsh' for call in self.calls))

    def test_inherited_pointer_skip_is_rejected_not_used(self):
        with patch.dict(os.environ, {'PILIPLUSX_SKIP_POINTER_FILTER_PATCH': '1'}):
            with self.assertRaisesRegex(ValueError, 'skip flag refused'):
                self.bootstrap().prepare()
        self.assertFalse(any(call[0][0] == 'pwsh' for call in self.calls))

    def test_tools_external_root_rejected_before_app_resolve(self):
        self.escape_tools = True
        with self.assertRaisesRegex(ValueError, 'escaped isolated sources'):
            self.bootstrap().prepare()
        self.assertFalse(any(call[0][0].endswith('flutter') for call in self.calls))

    def test_app_external_root_rejected_before_any_patch(self):
        self.escape_app = True
        with self.assertRaisesRegex(ValueError, 'escaped isolated sources'):
            self.bootstrap().prepare()
        self.assertFalse(any(call[0][0] == 'pwsh' for call in self.calls))

    def real_sdk_repository(self):
        self.real_sdk_git = True
        self.real_run(['git', 'init', str(self.sdk)], check=True, capture_output=True)
        # This real tracked binary has a path longer than 260 on this test host.
        relative = ('engine/src/flutter/testing/ios_scenario_app/ios/Scenarios/ScenariosUITests/'
                    'golden_platform_view_large_cliprrect_with_transform_multiple_clips_impeller_'
                    'iPhone SE (3rd generation)_26.2_simulator.png')
        path = self.sdk / relative
        path.parent.mkdir(parents=True)
        original = b'\x89PNG\r\n\x1a\noriginal binary\x00\xff'
        path.write_bytes(original)
        self.real_run(['git', '-C', str(self.sdk), 'add', '.'], check=True, capture_output=True)
        self.real_run(['git', '-C', str(self.sdk), '-c', 'user.name=Fixture',
                       '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'binary fixture'],
                      check=True, capture_output=True)
        return relative, path, original

    def test_real_dirty_binary_saves_all_diffs_and_exact_hashes_before_refusal(self):
        relative, path, original = self.real_sdk_repository()
        changed = b'\x89PNG\r\n\x1a\nchanged binary\x00\xfe'
        path.write_bytes(changed)
        self.real_run(['git', '-C', str(self.sdk), 'add', str(path)], check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, 'unknown modifications'):
            self.bootstrap().prepare_sdk()
        evidence = json.loads((self.args.output / 'original-sdk-state.json').read_text())
        item = next(item for item in evidence['files'] if item['path'] == relative)
        self.assertGreater(item['pathCharacters'], 260)
        self.assertEqual(item['expectedHead']['sha256'], hashlib.sha256(original).hexdigest())
        self.assertEqual(item['index']['sha256'], hashlib.sha256(changed).hexdigest())
        self.assertEqual(item['worktree']['sha256'], hashlib.sha256(changed).hexdigest())
        for name in ('status', 'working-diff', 'index-diff'):
            self.assertTrue((self.args.output / f'original-sdk-{name}.log').is_file())
        self.assertIn('GIT binary patch', (self.args.output / 'original-sdk-index-diff.log').read_text())
        self.assertEqual(path.read_bytes(), changed)
        self.assertFalse(any(call[0][0] == 'pwsh' for call in self.calls))

    def test_sdk_diff_failure_does_not_prevent_index_or_file_evidence(self):
        relative, path, original = self.real_sdk_repository()
        path.write_bytes(original + b'changed')
        self.sdk_diff_failure = True
        with self.assertRaisesRegex(ValueError, 'unreadable state'):
            self.bootstrap().prepare_sdk()
        evidence = json.loads((self.args.output / 'original-sdk-state.json').read_text())
        self.assertIn('working-diff', evidence['collectionErrors'])
        self.assertTrue((self.args.output / 'original-sdk-index-diff.log').exists())
        self.assertEqual(evidence['files'][0]['expectedHead']['sha256'], hashlib.sha256(original).hexdigest())
        receipt = json.loads((self.args.output / 'bootstrap.json').read_text())
        failed = next(step for step in receipt['steps'] if step['name'] == 'original-sdk-working-diff')
        self.assertEqual(failed['exitCode'], 7)

    def test_missing_sdk_binary_saves_head_and_explicit_worktree_read_error(self):
        relative, path, original = self.real_sdk_repository()
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'unknown modifications'):
            self.bootstrap().prepare_sdk()
        evidence = json.loads((self.args.output / 'original-sdk-state.json').read_text())
        item = next(item for item in evidence['files'] if item['path'] == relative)
        self.assertEqual(item['expectedHead']['sha256'], hashlib.sha256(original).hexdigest())
        self.assertIn('readError', item['worktree'])
        self.assertFalse(path.exists())

    def test_unknown_sdk_modification_preserved_and_refused(self):
        self.sdk_dirty = True
        (self.sdk / 'unknown.dart').write_text('preserve me')
        with self.assertRaisesRegex(ValueError, 'unknown modifications'):
            self.bootstrap().prepare()
        self.assertEqual((self.sdk / 'unknown.dart').read_text(), 'preserve me')
        self.assertFalse(any(call[0][0] == 'pwsh' for call in self.calls))

    def test_shared_sdk_copied_and_original_generated_cache_preserved(self):
        shared = self.root / 'shared-sdk'
        self.sdk_fixture(shared)
        original_config = shared / 'packages/flutter_tools/.dart_tool/package_config.json'
        self.config(original_config, {'flutter_tools': shared / 'packages/flutter_tools'})
        original_bytes = original_config.read_bytes()
        shutil = module.shutil
        shutil.rmtree(self.sdk)  # Fixture target only; production refuses existing targets.
        self.args.flutter_root = shared
        self.bootstrap().prepare()
        self.assertEqual(original_config.read_bytes(), original_bytes)
        sdk_calls = [call for call in self.calls if call[0][0].endswith(('dart', 'dart.exe'))]
        self.assertEqual(sdk_calls[0][1], self.private / 'f/packages/flutter_tools')
        self.assertFalse(any(call[0][0] == 'pwsh' and call[2]['FLUTTER_ROOT'] == str(shared) for call in self.calls))

    def test_private_cache_symlink_escape_stops_before_dependency_write(self):
        shared = self.root / 'shared-cache'
        shared.mkdir()
        try:
            (self.private / 'p').symlink_to(shared, target_is_directory=True)
        except OSError:
            self.skipTest('symlinks unavailable on this host')
        with self.assertRaisesRegex(ValueError, 'Pub cache escaped'):
            self.bootstrap().prepare()
        self.assertFalse(any(call[0][0].endswith(('dart', 'dart.exe')) for call in self.calls))
        self.assertEqual(list(shared.iterdir()), [])

    def test_business_rewrite_detected_not_declared_prepared(self):
        self.rewrite_source = True
        with self.assertRaisesRegex(ValueError, 'modified application/library'):
            self.bootstrap().prepare()
        receipt = json.loads((self.args.output / 'bootstrap.json').read_text())
        self.assertNotEqual(receipt['status'], 'prepared-source-only')

    def test_finalize_rejects_remote_advance_without_pulling(self):
        self.bootstrap().prepare()
        self.remote_drift = True
        with self.assertRaisesRegex(ValueError, 'source vector drift'):
            self.bootstrap().finalize()
        self.assertFalse(any('pull' in call[0] for call in self.calls))

    def test_finalize_rejects_relabeled_prepared_vector(self):
        self.bootstrap().prepare()
        self.app_sha = 'd' * 40
        self.args.expected_app_sha = self.app_sha
        with self.assertRaisesRegex(ValueError, 'differs from prepared vector'):
            self.bootstrap().finalize()

    def test_finalize_rejects_source_change(self):
        self.bootstrap().prepare()
        (self.app / 'lib/main.dart').write_text('later mutation')
        with self.assertRaisesRegex(ValueError, 'Sources or package resolution changed'):
            self.bootstrap().finalize()

    def test_cli_failure_writes_failed_receipt(self):
        self.failure = '-PackagesOnly'
        argv = ['prepare_routing_ci.py', '--app-root', str(self.app), '--media-kit-root', str(self.media),
                '--flutter-root', str(self.sdk), '--private-root', str(self.private), '--output', str(self.args.output),
                '--expected-app-sha', self.app_sha, '--expected-media-kit-sha', self.media_sha, '--platform', 'linux']
        with patch.object(sys, 'argv', argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            module.main()
        self.assertEqual(raised.exception.code, 1)
        receipt = json.loads((self.args.output / 'bootstrap.json').read_text())
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['steps'][-1]['exitCode'], 23)


class PackageRootsTest(unittest.TestCase):
    def test_missing_media_member_and_stale_media_member_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            config = root / 'package_config.json'
            config.write_text(json.dumps({'packages': []}))
            with self.assertRaisesRegex(ValueError, 'Missing media-kit packages'):
                module.verify(config, root)
            (root / 'media_kit').mkdir()
            old = root / 'old'
            old.mkdir()
            config.write_text(json.dumps({'packages': [{'name': 'media_kit', 'rootUri': old.as_uri()}]}))
            with self.assertRaisesRegex(ValueError, 'supplied media-kit checkout'):
                module.verify(config, root)

    def test_duplicate_and_network_roots_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            config = root / 'package_config.json'
            config.write_text(json.dumps({'packages': [{'name': 'x', 'rootUri': root.as_uri()}] * 2}))
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                module.package_roots(config, [root])
            config.write_text(json.dumps({'packages': [{'name': 'x', 'rootUri': 'https://example.com/x'}]}))
            with self.assertRaisesRegex(ValueError, 'Non-local'):
                module.package_roots(config, [root])


if __name__ == '__main__':
    unittest.main()
