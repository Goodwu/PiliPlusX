"""CPU-only protocol and real filesystem publication; native tool boundaries mocked."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
spec = importlib.util.spec_from_file_location('shared_core_bootstrap', SCRIPTS / 'package_macos_shared_core.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / 'Source.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Frameworks/Mpv.framework/Versions/A').mkdir(parents=True)
        (self.app / 'Contents/MacOS/Runner').write_bytes(b'Runner MediaKitSharedRenderer')
        (self.app / 'Contents/Frameworks/Mpv.framework/Versions/A/Mpv').write_bytes(b'old')
        self.info = self.app / 'Contents/Info.plist'
        self.write_info()
        self.output = self.root / 'Candidate.app'
        self.slices = {}
        for arch in ('arm64', 'x86_64'):
            p = self.root / (arch + '.dylib')
            p.write_bytes(arch.encode())
            self.slices[arch] = p
        self.manifest = self.root / 'slices.json'
        self.manifest.write_text(json.dumps({a: m.sha(p) for a, p in self.slices.items()}))
        self.source = self.root / 'prepared'
        self.source.mkdir()
        self.source_manifest = self.root / 'source.json'
        self.source_manifest.write_text('{}')
        self.argv = [str(self.app), str(self.output), *(str(p) for p in self.slices.values()),
                     str(self.manifest), '--prepared-source', str(self.source),
                     '--source-manifest', str(self.source_manifest)]

    def write_info(self, pending=None, include=False):
        values = {'CFBundleExecutable': 'Runner', 'Unrelated': 'preserved'}
        if include:
            values[m.PENDING] = pending
        self.info.write_bytes(plistlib.dumps(values))

    def shell(self, name, mode=None, **environment):
        env = {k: v for k, v in os.environ.items() if not k.startswith('PILIPLUSX_MPV_')}
        env.update(environment)
        if mode is not None:
            env['PILIPLUSX_MPV_BUNDLE_MODE'] = mode
        # A sentinel fails if any native gate is reached in an early-reject case.
        tools = self.root / 'sentinels'
        tools.mkdir(exist_ok=True)
        for tool in ('lipo', 'strings', 'otool', 'codesign', 'ditto', 'shasum'):
            p = tools / tool
            p.write_text('#!/bin/sh\necho native-tool-reached >&2\nexit 99\n')
            p.chmod(0o755)
        env['PATH'] = str(tools) + os.pathsep + os.environ['PATH']
        return subprocess.run(['bash', str(SCRIPTS / name), str(self.app)],
                              env=env, text=True, capture_output=True)

    def test_explicit_bootstrap_only_marks_without_native_tools(self):
        before = m.app_tree(self.app)
        result = self.shell('ensure_macos_mpv_bundle.sh', 'shared-candidate-bootstrap')
        self.assertEqual(result.returncode, 0, result.stderr)
        after = m.app_tree(self.app)
        self.assertEqual({k:v for k,v in before.items() if k != 'Contents/Info.plist'},
                         {k:v for k,v in after.items() if k != 'Contents/Info.plist'})
        self.assertIs(plistlib.loads(self.info.read_bytes())[m.PENDING], True)
        self.assertEqual(plistlib.loads(self.info.read_bytes())['Unrelated'], 'preserved')
        self.assertEqual(self.shell('ensure_macos_mpv_bundle.sh', 'shared-candidate-bootstrap').returncode, 0)

    def test_unknown_mode_rejects_before_modification(self):
        before = m.app_tree(self.app)
        for mode in ('', 'shared', 'SHARED-CANDIDATE-BOOTSTRAP', 'false'):
            result = self.shell('ensure_macos_mpv_bundle.sh', mode)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('native-tool-reached', result.stderr)
            self.assertEqual(m.app_tree(self.app), before)

    def test_default_legacy_still_checks_archive(self):
        bad = self.root / 'bad.tar.gz'
        bad.write_bytes(b'bad archive')
        result = self.shell('ensure_macos_mpv_bundle.sh', PILIPLUSX_MPV_ARCHIVE=str(bad))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('native-tool-reached', result.stderr)  # original shasum reached
        self.assertNotIn(m.PENDING, plistlib.loads(self.info.read_bytes()))

    def test_pending_presence_rejected_by_legacy_and_guard_even_with_mode(self):
        for value in (True, False, 'true', 0):
            self.write_info(value, True)
            before = m.app_tree(self.app)
            for script in ('ensure_macos_mpv_bundle.sh', 'verify_macos_mpv_bundle.sh'):
                mode = 'shared-candidate-bootstrap' if script.startswith('verify') else None
                result = self.shell(script, mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('native-tool-reached', result.stderr)
                self.assertIn('pending', result.stderr)
            self.assertEqual(m.app_tree(self.app), before)

    def test_bootstrap_malformed_pending_rejected(self):
        self.write_info(False, True)
        before = m.app_tree(self.app)
        result = self.shell('ensure_macos_mpv_bundle.sh', 'shared-candidate-bootstrap')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(m.app_tree(self.app), before)

    def test_guard_checks_info_before_missing_framework_or_version(self):
        self.write_info(True, True)
        shutil.rmtree(self.app / 'Contents/Frameworks')
        result = self.shell('verify_macos_mpv_bundle.sh')
        self.assertIn('bootstrap is pending', result.stderr)
        self.assertNotIn('Mpv.framework missing', result.stderr)

    def test_missing_info_rejects_bootstrap_and_guard(self):
        self.info.unlink()
        for script in ('ensure_macos_mpv_bundle.sh', 'verify_macos_mpv_bundle.sh'):
            result = self.shell(script, 'shared-candidate-bootstrap')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('native-tool-reached', result.stderr)

    def package(self, fault=None):
        calls = []
        before = m.app_tree(self.app)
        def output(command, **kwargs):
            command = list(map(str, command))
            if command[0] == 'lipo':
                return ('arm64 x86_64' if command[-1].endswith('/Runner')
                        else Path(command[-1]).stem)
            if command[0] == 'otool':
                return 'cmd LC_RPATH\ncmdsize 32\npath /locked/dependency (offset 12)\n'
            self.fail('unexpected native query: ' + repr(command))
        def run(*command):
            command = list(map(str, command))
            calls.append(command)
            self.assertFalse(self.output.exists(), 'published before gates')
            if command[:2] == ['codesign', '--verify'] and fault == 'source-sign':
                raise ValueError('bad source signature')
            if command[0] == 'ditto':
                self.assertNotEqual(Path(command[-1]), self.output)
                shutil.copytree(command[1], command[2], symlinks=True)
            elif command[0] == 'lipo' and '-thin' in command:
                shutil.copyfile(command[1], command[-1])
            elif command[0] == 'lipo' and '-create' in command:
                Path(command[-1]).write_bytes(b'shared universal')
            elif command[0].endswith('verify_macos_mpv_bundle.sh'):
                values = plistlib.loads((Path(command[-1]) / 'Contents/Info.plist').read_bytes())
                self.assertNotIn(m.PENDING, values)
                self.assertIs(values['MediaKitSharedRenderer'], True)
                if fault == 'bundle':
                    raise ValueError('bundle gate failed')
            elif any(p.endswith('verify_macos_shared_backend.py') for p in command):
                if fault == 'backend':
                    raise ValueError('backend gate failed')
                Path(command[-1]).write_text('{"both_architectures":"passed"}')
                if fault == 'drift':
                    (self.app / 'Contents/MacOS/Runner').write_bytes(b'externally changed')
                if fault == 'slice-drift':
                    self.slices['arm64'].write_bytes(b'externally changed')
                if fault == 'race':
                    self.output.mkdir()
        with patch.object(m, 'run', side_effect=run), patch.object(m.subprocess, 'check_output', side_effect=output):
            if fault:
                rejection = (self.assertRaisesRegex(ValueError, 'application link escapes root')
                             if fault == 'absolute-link'
                             else self.assertRaises((ValueError, FileExistsError)))
                with rejection:
                    m.main(self.argv)
                for suffix in m.SUFFIXES:
                    self.assertFalse(self.output.with_suffix(suffix).exists())
                if fault == 'race':
                    self.assertTrue(self.output.is_dir())
                else:
                    self.assertFalse(self.output.exists())
            else:
                m.main(self.argv)
                self.assertTrue(self.output.is_dir())
                for suffix in m.SUFFIXES:
                    self.assertTrue(self.output.with_suffix(suffix).is_file())
                self.assertEqual(calls[0][:4], ['codesign', '--verify', '--deep', '--strict'])
                self.assertEqual(m.app_tree(self.app), before)
        self.assertFalse(list(self.root.glob('.Candidate.shared-core-*')))
        if fault not in ('drift',):
            self.assertEqual(m.app_tree(self.app), before)
        return calls

    def test_core_full_chain_clears_only_private_copy_and_publishes_last(self):
        self.write_info(True, True)
        self.package()
        values = plistlib.loads((self.output / 'Contents/Info.plist').read_bytes())
        self.assertNotIn(m.PENDING, values)
        record = json.loads(self.output.with_suffix('.shared-core.json').read_text())
        self.assertIs(record['bootstrap_source_pending'], True)
        self.assertIs(plistlib.loads(self.info.read_bytes())[m.PENDING], True)

    def test_core_normal_source_remains_supported(self):
        self.package()
        self.assertIs(json.loads(self.output.with_suffix('.shared-core.json').read_text())['bootstrap_source_pending'], False)

    def test_core_source_sign_failure_cannot_clear_or_publish(self): self.package('source-sign')
    def test_core_bundle_failure_has_no_final_outputs(self): self.package('bundle')
    def test_core_backend_failure_has_no_final_outputs(self): self.package('backend')
    def test_core_source_drift_reported_not_cleaned(self): self.package('drift')
    def test_core_slice_drift_rejected(self): self.package('slice-drift')
    def test_core_racing_app_is_never_replaced(self): self.package('race')

    def test_existing_sidecar_rejected_before_native_tools(self):
        sidecar = self.output.with_suffix(m.SUFFIXES[0])
        sidecar.write_text('keep')
        with patch.object(m, 'run') as run, self.assertRaisesRegex(ValueError, 'already exists'):
            m.main(self.argv)
        run.assert_not_called()
        self.assertEqual(sidecar.read_text(), 'keep')

    def test_invalid_pending_rejected_without_output(self):
        self.write_info(False, True)
        with patch.object(m, 'run'), patch.object(m.subprocess, 'check_output', side_effect=['arm64', 'x86_64']), self.assertRaises(SystemExit):
            m.main(self.argv)
        self.assertFalse(self.output.exists())

    def test_external_symlink_source_refused(self):
        (self.app / 'Contents/escape').symlink_to(self.manifest)
        with patch.object(m, 'run') as run, self.assertRaisesRegex(ValueError, 'escapes'):
            m.main(self.argv)
        run.assert_not_called()

    def absolute_link_fixture(self, relative):
        original = self.app / relative
        backing = self.app / 'Contents' / ('Backing-' + original.name)
        original.rename(backing)
        original.symlink_to(backing)
        self.assertTrue(original.resolve().is_relative_to(self.app))
        calls = self.package('absolute-link')
        # Input verification and thin bridge reads are allowed; no staged
        # install-name modification, content rewrite or signing may happen.
        self.assertTrue(any(command[0] == 'ditto' for command in calls))
        self.assertFalse(any(command[0] == 'install_name_tool' for command in calls))
        self.assertFalse(any(command[0] == 'codesign' and '--sign' in command for command in calls))
        self.assertFalse(any(command[0] == 'lipo' and '-create' in command for command in calls))
        self.assertEqual(original.resolve(), backing)

    def test_copied_absolute_mpv_link_rejects_before_mutation(self):
        self.absolute_link_fixture('Contents/Frameworks/Mpv.framework/Versions/A/Mpv')

    def test_copied_absolute_info_link_rejects_before_mutation(self):
        self.absolute_link_fixture('Contents/Info.plist')

    def test_safe_relative_framework_link_copy_remains_supported(self):
        framework = self.app / 'Contents/Frameworks/Mpv.framework'
        (framework / 'Versions/Current').symlink_to('A')
        (framework / 'Mpv').symlink_to('Versions/Current/Mpv')
        self.package()
        self.assertEqual(os.readlink(self.output / 'Contents/Frameworks/Mpv.framework/Mpv'),
                         'Versions/Current/Mpv')

    def test_publish_late_app_race_rolls_back_only_own_sidecars(self):
        staged = self.root / 'Stage.app'
        staged.mkdir()
        for suffix in m.SUFFIXES:
            staged.with_suffix(suffix).write_text('evidence')
        def race(*args):
            self.output.mkdir()
            raise FileExistsError('race')
        with patch.object(m, 'publish_absent', side_effect=race), self.assertRaises(FileExistsError):
            m.publish(staged, self.output)
        self.assertTrue(self.output.is_dir())
        self.assertTrue(staged.is_dir())
        for suffix in m.SUFFIXES:
            self.assertFalse(self.output.with_suffix(suffix).exists())


if __name__ == '__main__':
    unittest.main()
