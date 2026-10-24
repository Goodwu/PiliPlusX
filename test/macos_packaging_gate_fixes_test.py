"""Focused CPU regressions for the final macOS bundle and publication gates."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


core = load('packaging_core_for_gate_fix_tests', ROOT / 'scripts/package_macos_shared_core.py')
closure = load('closure_for_gate_fix_tests', ROOT / 'scripts/verify_macos_mpv_closure.py')
wrapper = load('shared_build_wrapper_for_gate_fix_tests', ROOT / 'scripts/package_macos_shared_build.py')


class ClosureGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Fixture.app'
        self.frameworks = self.app / 'Contents/Frameworks'
        self.frameworks.mkdir(parents=True)
        (self.app / 'Contents/MacOS').mkdir()
        (self.app / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleExecutable': 'Runner'}))
        self.executable = self.app / 'Contents/MacOS/Runner'
        self.executable.write_text('runner')
        self.mpv = self.frameworks / 'Mpv.framework/Versions/A/Mpv'
        self.mpv.parent.mkdir(parents=True)
        self.mpv.write_text('mpv')
        for name in ('libplacebo.dylib', 'libvulkan.1.dylib', 'libshaderc_shared.1.dylib'):
            (self.frameworks / name).write_text(name)
        self.extra = self.frameworks / 'Runtime With Spaces' / 'lib helper.dylib'
        self.extra.parent.mkdir()
        self.extra.write_text('helper')
        key = lambda path: str(path.resolve())
        self.deps = {key(self.executable): [], key(self.mpv): [
            '@rpath/Runtime With Spaces/lib helper.dylib'],
            key(self.extra): [],
            **{key(self.frameworks / name): [] for name in (
                'libplacebo.dylib', 'libvulkan.1.dylib', 'libshaderc_shared.1.dylib')}}

    def command(self, *args):
        if args[0] == 'lipo':
            return 'arm64 x86_64'
        if args[0:3] == ('otool', '-arch', 'arm64') or args[0:3] == ('otool', '-arch', 'x86_64'):
            binary = args[-1]
            if args[3] == '-l':
                return 'cmd LC_BUILD_VERSION\nminos 12.0.0'
            if args[3] == '-L':
                names = self.deps.get(str(Path(binary).resolve()), [])
                return binary + ''.join(f'\n\t{name} (compatibility version 1.0.0, current version 1.0.0)'
                                        for name in names)
        raise AssertionError(args)

    def verify(self):
        with patch.object(closure, 'command', side_effect=self.command):
            with contextlib.redirect_stdout(io.StringIO()):
                closure.verify(self.app)

    def test_internal_framework_link_and_dependency_name_with_spaces_pass(self):
        real = self.frameworks / 'Real.framework/Versions/A/Real'
        real.parent.mkdir(parents=True)
        real.write_text('framework')
        alias = self.frameworks / 'Alias.framework/Versions/A/Alias'
        alias.parent.mkdir(parents=True)
        alias.symlink_to(real)
        self.deps[str(self.extra.resolve())] = ['@rpath/Alias.framework/Versions/A/Alias']
        self.verify()

    def test_all_relative_prefixes_reject_existing_external_targets(self):
        outside = self.root / 'external.dylib'
        outside.write_text('outside')
        escapes = {
            '@rpath/../../../external.dylib',
            '@loader_path/../../../../../../external.dylib',
            '@executable_path/../../../external.dylib',
        }
        for dependency in escapes:
            with self.subTest(dependency=dependency):
                self.deps[str(self.mpv.resolve())] = [dependency]
                with self.assertRaisesRegex(ValueError, 'escapes application bundle'):
                    self.verify()

    def test_external_root_symlink_is_rejected(self):
        outside = self.root / 'external.dylib'
        outside.write_text('outside')
        link = self.frameworks / 'external.dylib'
        link.symlink_to(outside)
        self.deps[str(self.mpv.resolve())] = ['@rpath/external.dylib']
        with self.assertRaisesRegex(ValueError, 'escapes application bundle'):
            self.verify()

    def test_dependency_row_without_compatibility_metadata_fails_closed(self):
        self.deps[str(self.mpv.resolve())] = ['@rpath/missing dylib']
        original = self.command
        def malformed(*args):
            if (len(args) > 3 and args[0] == 'otool'
                    and Path(args[-1]).resolve() == self.mpv.resolve() and args[3] == '-L'):
                return str(self.mpv) + '\n\t@rpath/missing dylib'
            return original(*args)
        with patch.object(closure, 'command', side_effect=malformed):
            with self.assertRaisesRegex(ValueError, 'unrecognized'):
                closure.verify(self.app)

    def test_empty_architecture_set_fails_closed(self):
        def no_arch(*args):
            if args[0] == 'lipo':
                return ''
            return self.command(*args)
        with patch.object(closure, 'command', side_effect=no_arch):
            with self.assertRaisesRegex(ValueError, 'empty or invalid architecture'):
                closure.verify(self.app)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        if sys.platform != 'darwin':
            self.skipTest('renamex_np regression requires macOS')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / 'Candidate.app'
        self.staged = self.root / 'Staged.app'
        self.staged.mkdir()
        (self.staged / 'marker').write_text('app')
        for suffix in ('.shared-core.json', '.shared-backend.json'):
            self.staged.with_suffix(suffix).write_text(suffix)

    def test_directory_collision_is_not_replaced_and_owned_sidecars_roll_back(self):
        collision_inode = None
        def collide_then_exclusive_rename(stage, destination):
            nonlocal collision_inode
            destination.mkdir()
            collision_inode = destination.stat().st_ino
            core.publish_absent(stage, destination)
        with patch.object(wrapper, 'publish_absent', side_effect=collide_then_exclusive_rename):
            with self.assertRaises(FileExistsError):
                wrapper.publish(self.staged, self.output)
        self.assertEqual(self.output.stat().st_ino, collision_inode)
        self.assertFalse((self.output / 'marker').exists())
        self.assertFalse(self.output.with_suffix('.shared-core.json').exists())
        self.assertFalse(self.output.with_suffix('.shared-backend.json').exists())
        self.assertTrue(self.staged.is_dir())

    def test_rollback_preserves_sidecar_replaced_after_our_link(self):
        sidecar = self.output.with_suffix('.shared-core.json')
        def replace_then_fail(_stage, _destination):
            sidecar.unlink()
            sidecar.write_text('foreign replacement')
            raise OSError('injected exclusive rename failure')
        with patch.object(wrapper, 'publish_absent', side_effect=replace_then_fail):
            with self.assertRaisesRegex(OSError, 'injected exclusive rename failure'):
                wrapper.publish(self.staged, self.output)
        self.assertEqual(sidecar.read_text(), 'foreign replacement')
        self.assertFalse(self.output.with_suffix('.shared-backend.json').exists())

    def test_successful_absent_target_publication_installs_app_and_sidecars(self):
        wrapper.publish(self.staged, self.output)
        self.assertEqual((self.output / 'marker').read_text(), 'app')
        self.assertTrue(self.output.with_suffix('.shared-core.json').is_file())
        self.assertTrue(self.output.with_suffix('.shared-backend.json').is_file())
        self.assertFalse(self.staged.exists())


if __name__ == '__main__':
    unittest.main()
