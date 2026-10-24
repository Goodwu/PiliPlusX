"""Focused publication/safety tests; actual Mach-O validation runs separately."""
import argparse
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare_macos_shared_inputs.py'
spec = importlib.util.spec_from_file_location('prepared_inputs', SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class PreparedInputsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.signatures_patch = patch.object(m, 'verify_signatures')
        self.signatures_patch.start()
        self.addCleanup(self.signatures_patch.stop)
        self.dest = self.root / 'output'
        self.recipe = self.root / 'repo/tool/shared'
        self.recipe.mkdir(parents=True)
        for name in m.RECIPE_FILES:
            (self.recipe / name).write_text(name)
        self.calls = []
        self.builder = types.SimpleNamespace(inspect_dependencies=self.inspect)
        self.args = argparse.Namespace(recipe=self.recipe, output=self.dest,
                                      runtime_work=self.root / 'runtime-work',
                                      runtime_directory=self.root / 'runtime-out',
                                      library_root=[], libass_library=self.root / 'ass/file',
                                      uchardet_header=self.root / 'header/file')
        for name in m.PINNED:
            setattr(self.args, name, self.root / name / 'file')

    def inspect(self, config, arches):
        p = Path(config['architectures']['arm64']['prefix'])
        self.assertTrue(p.exists(), 'must inspect real existing paths')
        self.calls.append(p)
        return {'architectures': {'arm64': {'paths': {'prefix': str(p)},
                'libraries': {str(p / 'file'): {'sha256': m.sha(p / 'file')}}}}}

    def populate(self, args, stage, *unused):
        (stage / 'prefix').mkdir()
        (stage / 'prefix/file').write_text('actual payload')
        (stage / 'archive').mkdir()
        (stage / 'archive/mpv.tar.gz').write_text('mpv test archive')
        return ({'architectures': {'arm64': {'prefix': str(stage / 'prefix')}}},
                {'recipe': {n: m.sha(self.recipe / n) for n in m.RECIPE_FILES}})

    def prepare(self):
        with patch.object(m, 'load_module', return_value=self.builder), \
             patch.object(m, 'populate', side_effect=self.populate), \
             patch.object(m, 'signature_payload'), patch.object(m, 'verify_signatures'):
            return m.prepare(self.args)

    def test_real_final_path_inspection_before_seal(self):
        manifest = self.prepare()
        self.assertEqual(len(self.calls), 2)
        self.assertNotEqual(self.calls[0], self.calls[1])
        self.assertEqual(self.calls[1], self.dest / 'prefix')
        saved_stage = json.loads((self.dest / 'stage-inspection.json').read_text())
        self.assertIn(str(self.calls[0] / 'file'), saved_stage['architectures']['arm64']['libraries'])
        lock = json.loads((self.dest / 'sealed/dependency-lock.json').read_text())
        self.assertIn(str(self.calls[1] / 'file'), lock['architectures']['arm64']['libraries'])
        self.assertEqual(manifest['files'], {k: v for k, v in m.files(self.dest).items()
                         if k != 'sealed/inputs-manifest.json'})

    def test_final_inspection_failure_has_no_output_or_lock(self):
        original = self.builder.inspect_dependencies
        def final_fail(c, a):
            if Path(c['architectures']['arm64']['prefix']).is_relative_to(self.dest):
                self.assertFalse((self.dest / 'sealed').exists())
                raise ValueError('injected real-final-path failure')
            return original(c, a)
        self.builder.inspect_dependencies = final_fail
        with self.assertRaisesRegex(ValueError, 'real-final-path'):
            self.prepare()
        self.assertFalse(self.dest.exists())
        self.assertFalse(list(self.root.glob('.output.preparing-*')))

    def test_final_inspection_identity_mismatch_rolls_back(self):
        original = self.builder.inspect_dependencies
        def changed(c, a):
            report = original(c, a)
            if Path(c['architectures']['arm64']['prefix']).is_relative_to(self.dest):
                report['unexpected'] = 'changed'
            return report
        self.builder.inspect_dependencies = changed
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.prepare()
        self.assertFalse(self.dest.exists())

    def test_seal_failure_removes_only_created_output(self):
        survivor = self.root / 'keep'
        survivor.write_text('unrelated')
        original = m.publish_absent
        def publish(stage, dest):
            if dest.name == 'sealed':
                raise OSError('injected seal failure')
            original(stage, dest)
        with patch.object(m, 'publish_absent', side_effect=publish), \
             self.assertRaisesRegex(OSError, 'seal failure'):
            self.prepare()
        self.assertFalse(self.dest.exists())
        self.assertEqual(survivor.read_text(), 'unrelated')
        self.assertFalse(list(self.root.glob('.sealing-*')))

    def test_existing_output_preserved(self):
        self.dest.mkdir()
        (self.dest / 'keep').write_text('keep')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.prepare()
        self.assertEqual((self.dest / 'keep').read_text(), 'keep')

    def test_overlap_input_and_ancestor_rejected(self):
        protected = self.root / 'dependencies'
        protected.mkdir()
        for dest in (protected / 'child', self.root):
            with self.assertRaises(ValueError):
                m.check_output(dest, [protected])

    def test_application_output_rejected(self):
        app = self.root / 'product.app'
        app.mkdir()
        with self.assertRaisesRegex(ValueError, 'application'):
            m.check_output(app / 'candidate', [])

    def test_symlink_output_ancestor_rejected(self):
        real = self.root / 'real'
        real.mkdir()
        link = self.root / 'link'
        link.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            m.check_output(link / 'output', [])

    def test_symlink_input_file_and_directory_rejected(self):
        target = self.root / 'target'
        target.write_text('x')
        link = self.root / 'link'
        link.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            m.checked_path(link)
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            m.files(self.root)

    def test_special_input_file_rejected_without_opening(self):
        import os
        fifo = self.root / 'fifo'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, 'incorrect input type'):
            m.checked_path(fifo)

    def test_publish_does_not_replace_existing_empty_directory(self):
        stage = self.root / 'stage'
        stage.mkdir()
        self.dest.mkdir()
        with self.assertRaises(OSError):
            m.publish_absent(stage, self.dest)
        self.assertTrue(stage.is_dir())
        self.assertTrue(self.dest.is_dir())

    def unsafe_tar(self, members):
        archive = self.root / 'test.tar'
        with tarfile.open(archive, 'w') as t:
            for name, kind in members:
                info = tarfile.TarInfo(name)
                info.type = kind
                if kind == tarfile.REGTYPE:
                    info.size = 1
                    t.addfile(info, io.BytesIO(b'x'))
                else:
                    info.linkname = 'elsewhere'
                    t.addfile(info)
        dest = self.root / 'extract'
        dest.mkdir()
        return archive, dest

    def test_unsafe_unselected_archive_member_rejected(self):
        for i, member in enumerate((('../escape', tarfile.REGTYPE),
                ('/absolute', tarfile.REGTYPE), ('link', tarfile.SYMTYPE),
                ('hard', tarfile.LNKTYPE), ('device', tarfile.CHRTYPE))):
            with self.subTest(member=member):
                root = self.root / str(i)
                root.mkdir()
                archive = root / 'bad.tar'
                with tarfile.open(archive, 'w') as t:
                    info = tarfile.TarInfo(member[0])
                    info.type = member[1]
                    t.addfile(info)
                with self.assertRaisesRegex(ValueError, 'unsafe'):
                    m.extract_selected(archive, root / 'extract', lambda p: None)

    def test_duplicate_archive_members_rejected(self):
        archive, dest = self.unsafe_tar([('a', tarfile.REGTYPE)] * 2)
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            m.extract_selected(archive, dest, lambda p: None)

    def test_relocation_only_maps_path_boundaries(self):
        old, new = Path('/stage'), Path('/final')
        value = {'/stage/a': ['/stage', '/stage/b', '/stage-other', 'sha256']}
        self.assertEqual(m.relocate(value, old, new),
                         {'/final/a': ['/final', '/final/b', '/stage-other', 'sha256']})

    def test_verify_rejects_missing_seal(self):
        self.dest.mkdir()
        with self.assertRaises(ValueError):
            m.verify(self.dest, self.recipe)

    def test_verify_rejects_self_consistently_resealed_dotdot_escape(self):
        self.prepare()
        escape = self.root / 'escape'
        escape.mkdir()
        (escape / 'file').write_text('actual payload')
        config_path = self.dest / 'sealed/dependency-config.json'
        lock_path = self.dest / 'sealed/dependency-lock.json'
        manifest_path = self.dest / 'sealed/inputs-manifest.json'
        config = json.loads(config_path.read_text())
        # This passes lexical is_relative_to(output) but resolves outside it.
        config['architectures']['arm64']['prefix'] = str(self.dest) + '/../escape'
        m.write_json(config_path, config)
        m.write_json(lock_path, self.inspect(config, m.ARCHES))
        manifest = json.loads(manifest_path.read_text())
        for path in (config_path, lock_path):
            manifest['files'][str(path.relative_to(self.dest))] = m.sha(path)
        m.write_json(manifest_path, manifest)
        with patch.object(m, 'load_module', return_value=self.builder), \
             self.assertRaisesRegex(ValueError, 'noncanonical or escaping'):
            m.verify(self.dest, self.recipe)

    def test_verify_detects_extra_tamper_symlink_and_recipe_drift(self):
        self.prepare()
        archive = self.dest / 'archive/mpv.tar.gz'
        with patch.object(m, 'load_module', return_value=self.builder), \
             patch.dict(m.PINNED, {'mpv_archive': m.sha(archive)}):
            m.verify(self.dest, self.recipe)
            extra = self.dest / 'extra'
            extra.write_text('extra')
            with self.assertRaisesRegex(ValueError, 'file set/hash'):
                m.verify(self.dest, self.recipe)
            extra.unlink()
            payload = self.dest / 'prefix/file'
            before = payload.read_bytes()
            payload.write_text('tampered')
            with self.assertRaisesRegex(ValueError, 'file set/hash'):
                m.verify(self.dest, self.recipe)
            payload.write_bytes(before)
            extra.symlink_to(payload)
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                m.verify(self.dest, self.recipe)
            extra.unlink()
            (self.recipe / 'build_macos.py').write_text('changed')
            with self.assertRaisesRegex(ValueError, 'recipe identity'):
                m.verify(self.dest, self.recipe)


class SignaturePolicyTests(unittest.TestCase):
    """Real file/copy/lipo-shape fixtures; codesign/otool/lipo are mocked."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.stage = self.root / 'stage'
        (self.stage / 'lib').mkdir(parents=True)
        self.path = self.stage / 'lib/libtest.dylib'
        self.actions = []
        self.sign_failure = False
        self.corrupt_preserved = False
        self.data = {'arm64': {'content': 'A-original', 'signature': 'valid', 'cdhash': 'a' * 40},
                     'x86_64': {'content': 'X-original', 'signature': 'none', 'cdhash': None}}
        self.write(self.path, self.data)
        self.builder = type('Builder', (), {})()
        self.builder.output = self.tool_output
        self.builder.library_identity = self.identity
        self.tool_patch = patch.object(m, 'signature_tool', side_effect=self.signature_tool)
        self.tool_patch.start()
        self.addCleanup(self.tool_patch.stop)

    def write(self, p, value):
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(value, sort_keys=True))

    def read(self, p):
        return json.loads(Path(p).read_text())

    def identity(self, p, arch):
        return {'architectures': list(self.read(p)), 'minos': '12.0',
                'install_dependencies': ['@rpath/' + Path(p).name if Path(p).name.endswith('.dylib')
                                         and Path(p).name != 'universal.dylib' else '@rpath/libtest.dylib'],
                'sha256': m.sha(p)}

    def tool_output(self, command):
        command = [str(x) for x in command]
        self.actions.append(command)
        if command[0] == 'otool':
            d = self.read(command[-1])[command[2]]
            return 'cmd LC_CODE_SIGNATURE' if d['signature'] != 'none' else ''
        if command[0] == 'lipo' and '-thin' in command:
            arch = command[command.index('-thin') + 1]
            self.write(Path(command[-1]), {arch: self.read(command[1])[arch]})
            return ''
        if command[0] == 'lipo' and '-create' in command:
            result = {}
            for source in command[2:-2]:
                result.update(self.read(source))
            if self.corrupt_preserved:
                result['arm64']['content'] += '-corrupted'
            self.write(Path(command[-1]), result)
            return ''
        self.fail('unexpected mock builder tool: ' + repr(command))

    def signature_tool(self, command):
        command = [str(x) for x in command]
        self.actions.append(command)
        p = Path(command[-1])
        if '--sign' in command:
            self.assertNotIn('--force', command)
            if self.sign_failure:
                return 1, 'injected signing failure'
            data = self.read(p)
            self.assertTrue(all(v['signature'] == 'none' for v in data.values()))
            for value in data.values():
                value.update(signature='valid', cdhash='b' * 40)
            self.write(p, data)
            return 0, ''
        arch = command[command.index('--arch') + 1]
        if p.is_dir():
            name = p.name[:-10]
            if not (p / 'Versions/A/Resources/Info.plist').is_file():
                return 1, 'invalid Info.plist'
            p = p / 'Versions/A' / name
        d = self.read(p)[arch]
        if d['signature'] == 'none':
            return 1, 'code object is not signed at all'
        if '--display' in command:
            return 0, 'CDHash=' + d['cdhash'] + '\n'
        return (0, '') if d['signature'] == 'valid' else (1, 'invalid signed bytes')

    def test_mixed_signs_only_unsigned_intel_and_preserves_arm_bytes(self):
        record = m.normalize_flat_signature(self.path, self.builder)
        signed = [c for c in self.actions if '--sign' in c]
        self.assertEqual(len(signed), 1)
        self.assertTrue(signed[0][-1].endswith('/x86_64'))
        self.assertEqual(record['signed_slice_preservation']['arm64']['cdhash'], 'a' * 40)
        self.assertEqual(record['slice_sha256']['arm64']['source'], record['slice_sha256']['arm64']['derived'])
        self.assertNotEqual(record['source_sha256'], record['derived_sha256'])
        self.assertEqual(self.read(self.path)['arm64'], self.data['arm64'])

    def test_fully_signed_input_preserves_whole_bytes_without_signing(self):
        self.data['x86_64'].update(signature='valid', cdhash='c' * 40)
        self.write(self.path, self.data)
        before = self.path.read_bytes()
        record = m.normalize_flat_signature(self.path, self.builder)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(record['actions'], [])
        self.assertFalse(any('--sign' in c for c in self.actions))

    def test_existing_invalid_arm_signature_is_never_repaired(self):
        self.data['arm64']['signature'] = 'bad'
        self.write(self.path, self.data)
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, 'refusing repair'):
            m.normalize_flat_signature(self.path, self.builder)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse(any('--sign' in c for c in self.actions))

    def test_no_lc_but_successful_display_is_ambiguous_unsigned(self):
        self.builder.output = lambda command: ''
        with self.assertRaisesRegex(ValueError, 'ambiguous unsigned'):
            m.signature_state(self.path, 'arm64', self.builder)
        self.assertFalse(any('--sign' in c for c in self.actions))

    def test_sign_failure_does_not_change_stage_source(self):
        self.sign_failure = True
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, 'signing failed'):
            m.normalize_flat_signature(self.path, self.builder)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse(list(self.stage.glob('.unsigned-slices-*')))

    def test_lipo_corruption_of_preserved_slice_is_rejected(self):
        self.corrupt_preserved = True
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, 'signed arm64 slice was modified'):
            m.normalize_flat_signature(self.path, self.builder)
        self.assertEqual(self.path.read_bytes(), before)

    def context_fixture(self):
        source_root = self.root / 'source/Test.framework'
        source = source_root / 'Versions/A/Test'
        both = json.loads(json.dumps(self.data))
        both['x86_64'].update(signature='valid', cdhash='c' * 40)
        self.write(source, both)
        resources = source.parent / 'Resources'
        resources.mkdir()
        (resources / 'Info.plist').write_text('signed original metadata')
        (source_root / 'Versions/Current').symlink_to('A', target_is_directory=True)
        (source_root / 'Test').symlink_to('Versions/Current/Test')
        (source_root / 'Resources').symlink_to('Versions/Current/Resources', target_is_directory=True)
        staged = self.stage / 'lib/Test.framework/Versions/A/Test'
        staged.parent.mkdir(parents=True)
        staged.write_bytes(source.read_bytes())
        record = {'sha256': m.sha(staged), 'architectures': list(m.ARCHES)}
        lock = {'architectures': {a: {'libraries': {str(staged): record}} for a in m.ARCHES}}
        self.builder.inspect_dependencies = lambda *args: lock
        provenance = {'external_closure_files': {str(source): m.sha(source)}}
        m.signature_payload(self.stage, {}, provenance, self.builder)
        return source_root, staged, lock, provenance

    def test_framework_context_copy_preserves_binary_and_internal_links(self):
        root, staged, lock, provenance = self.context_fixture()
        context = self.stage / 'framework-context/Test.framework'
        self.assertEqual(m.sha(staged), m.sha(context / 'Versions/A/Test'))
        self.assertEqual(m.tree_files(root, True), m.tree_files(context, True))
        self.assertEqual(m.files(self.stage)['framework-context/Test.framework/Resources'],
                         {'symlink': 'Versions/Current/Resources'})
        self.assertFalse(any('--sign' in c for c in self.actions))
        m.verify_signatures(self.stage, lock, provenance, self.builder)

    def test_standalone_context_verification_does_not_need_original_source(self):
        import shutil
        root, staged, lock, provenance = self.context_fixture()
        shutil.rmtree(root)
        m.verify_signatures(self.stage, lock, provenance, self.builder)

    def test_context_binary_mismatch_or_metadata_tamper_is_rejected(self):
        root, staged, lock, provenance = self.context_fixture()
        metadata = self.stage / 'framework-context/Test.framework/Versions/A/Resources/Info.plist'
        metadata.write_text('modified metadata')
        with self.assertRaisesRegex(ValueError, 'binary/tree'):
            m.verify_signatures(self.stage, lock, provenance, self.builder)
        metadata.write_text('signed original metadata')
        binary = self.stage / 'framework-context/Test.framework/Versions/A/Test'
        binary.write_text('different binary')
        with self.assertRaisesRegex(ValueError, 'binary/tree'):
            m.verify_signatures(self.stage, lock, provenance, self.builder)

    def test_framework_context_rejects_external_absolute_broken_and_special(self):
        root = self.root / 'context'
        root.mkdir()
        (root / 'file').write_text('file')
        link = root / 'link'
        for target in ('../outside', str(root / 'file'), 'missing'):
            with self.subTest(target=target):
                link.symlink_to(target)
                with self.assertRaises(ValueError):
                    m.tree_files(root, True)
                link.unlink()
        import os
        os.mkfifo(root / 'fifo')
        with self.assertRaisesRegex(ValueError, 'unsupported input entry'):
            m.tree_files(root, True)



if __name__ == '__main__':
    unittest.main()
