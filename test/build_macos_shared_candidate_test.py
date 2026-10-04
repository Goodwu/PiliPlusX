"""Actual filesystem and mocked tool-boundary tests for candidate publication."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/build_macos_shared_candidate.py'
spec = importlib.util.spec_from_file_location('candidate_consumer', SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / 'Source.app'
        (self.app / 'Contents/Frameworks').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        (self.app / 'Contents/Resources/file').write_text('source')
        (self.app / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleExecutable': 'Runner'}))
        self.inputs = self.root / 'inputs'
        (self.inputs / 'lib').mkdir(parents=True)
        self.recipe = self.root / 'repo/tool/shared'
        self.recipe.mkdir(parents=True)
        for name in m.RECIPE_KEYS:
            (self.recipe / name).write_text(name)
        self.args = argparse.Namespace(input_app=self.app, inputs=self.inputs,
            recipe=self.recipe, work_dir=self.root / 'work', published_dir=self.root / 'published',
            output_app=self.root / 'Candidate.app', log_dir=self.root / 'logs',
            resume=False, jobs=4, check_inputs=False, input_kind='unknown')
        self.lock = {'schema_version': 1, 'architectures': {}}
        for arch in m.ARCHES:
            self.lock['architectures'][arch] = {'libraries': {}}
        self.library('libass.dylib')
        self.builder = types.SimpleNamespace(OPTIONS={'gpl': False},
              verify_source=lambda *args: {'source_tree_sha256': 'full-tree'},
              publication_files=lambda path: {'arm64/libmpv.2.dylib': 'slice'})

    def library(self, relative):
        p = self.inputs / 'lib' / relative
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('signed universal ' + relative)
        for arch in m.ARCHES:
            self.lock['architectures'][arch]['libraries'][str(p)] = {
                'sha256': m.sha(p), 'architectures': list(m.ARCHES),
                'install_dependencies': ['@rpath/' + relative]}
        return p

    def test_plan_accepts_universal_flat_and_framework(self):
        self.library('Freetype.framework/Versions/A/Freetype')
        plan = m.library_plan(self.inputs, self.lock)
        self.assertEqual(len(plan), 2)
        self.assertEqual(plan['@rpath/Freetype.framework/Versions/A/Freetype']['framework'], 'Freetype.framework')

    def test_plan_rejects_thin_even_with_matching_bytes(self):
        for arch in m.ARCHES:
            next(iter(self.lock['architectures'][arch]['libraries'].values()))['architectures'] = ['arm64']
        with self.assertRaisesRegex(ValueError, 'universal whole-file'):
            m.library_plan(self.inputs, self.lock)

    def test_plan_rejects_hash_mismatch(self):
        (self.inputs / 'lib/libass.dylib').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'whole-file SHA'):
            m.library_plan(self.inputs, self.lock)

    def test_plan_rejects_escaping_and_noncanonical_id(self):
        entry = next(iter(self.lock['architectures']['arm64']['libraries'].values()))
        for install_id in ('@rpath/../escape.dylib', '@rpath/a/../libass.dylib', '/opt/homebrew/libass.dylib'):
            with self.subTest(install_id=install_id):
                entry['install_dependencies'] = [install_id]
                with self.assertRaises(ValueError):
                    m.library_plan(self.inputs, self.lock)

    def test_plan_rejects_different_architecture_closure(self):
        self.lock['architectures']['x86_64']['libraries'] = {}
        with self.assertRaisesRegex(ValueError, 'empty'):
            m.library_plan(self.inputs, self.lock)

    def test_plan_rejects_source_install_id_disagreement(self):
        for arch in m.ARCHES:
            next(iter(self.lock['architectures'][arch]['libraries'].values()))['install_dependencies'] = ['@rpath/other.dylib']
        with self.assertRaisesRegex(ValueError, 'disagrees'):
            m.library_plan(self.inputs, self.lock)

    def test_plan_rejects_external_or_symlink_source(self):
        source = self.inputs / 'lib/libass.dylib'
        saved = source.read_bytes()
        source.unlink()
        external = self.root / 'external'
        external.write_bytes(saved)
        source.symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            m.library_plan(self.inputs, self.lock)

    def test_app_tree_covers_internal_link_target_and_bytes(self):
        link = self.app / 'Contents/Resources/alias'
        link.symlink_to('file')
        before = m.app_tree(self.app)
        self.assertEqual(before['Contents/Resources/alias']['target'], 'file')
        other = self.app / 'Contents/Resources/other'
        other.write_text('source')
        link.unlink()
        link.symlink_to('other')
        self.assertNotEqual(before, m.app_tree(self.app))
        other.write_text('new bytes')
        self.assertNotEqual(before, m.app_tree(self.app))

    def test_app_tree_rejects_external_symlink_and_special_file(self):
        link = self.app / 'Contents/Resources/link'
        link.symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            m.app_tree(self.app)
        link.unlink()
        fifo = self.app / 'Contents/Resources/fifo'
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, 'special'):
            m.app_tree(self.app)

    def test_preflight_rejects_each_existing_output(self):
        for p in (self.args.output_app, *(self.args.output_app.with_suffix(s) for s in m.SUFFIXES)):
            p.write_text('foreign')
            with self.assertRaisesRegex(ValueError, 'already exists'):
                m.preflight(self.args)
            self.assertEqual(p.read_text(), 'foreign')
            p.unlink()

    def test_preflight_rejects_overlap_with_inputs_or_app(self):
        for path in (self.inputs / 'Candidate.app', self.app / 'Child.app', self.root / 'repo/Candidate.app'):
            self.args.output_app = path
            with self.assertRaises(ValueError):
                m.preflight(self.args)

    def test_preflight_rejects_sidecar_overlap_for_all_owned_paths(self):
        for key in ('work_dir', 'published_dir', 'log_dir'):
            original = getattr(self.args, key)
            for suffix in m.SUFFIXES:
                sidecar = self.args.output_app.with_suffix(suffix)
                for path in (sidecar, sidecar / 'nested'):
                    with self.subTest(key=key, path=path):
                        setattr(self.args, key, path)
                        self.args.check_inputs = True
                        with self.assertRaises(ValueError):
                            m.preflight(self.args)
            setattr(self.args, key, original)

    def test_preflight_fresh_and_resume_identity_requirements(self):
        self.args.work_dir.mkdir()
        with self.assertRaisesRegex(ValueError, 'fresh'):
            m.preflight(self.args)
        self.args.resume = True
        with self.assertRaisesRegex(ValueError, 'builder state'):
            m.preflight(self.args)

    def staged_candidate(self):
        staged = self.root / 'Packaged.app'
        staged.mkdir()
        for suffix in m.SUFFIXES:
            staged.with_suffix(suffix).write_text(suffix)
        return staged

    def test_exclusive_publish_app_last(self):
        staged = self.staged_candidate()
        def publish(source, dest):
            self.assertTrue(all(dest.with_suffix(s).is_file() for s in m.SUFFIXES))
            source.rename(dest)
        m.publish_candidate(staged, self.args.output_app, publish)
        self.assertTrue(self.args.output_app.is_dir())

    def test_publish_failure_removes_only_owned_sidecars(self):
        staged = self.staged_candidate()
        def fail_publish(source, dest):
            raise OSError('injected exclusive rename failure')
        with self.assertRaisesRegex(OSError, 'rename failure'):
            m.publish_candidate(staged, self.args.output_app, fail_publish)
        self.assertTrue(staged.is_dir())
        self.assertFalse(self.args.output_app.exists())
        self.assertFalse(any(self.args.output_app.with_suffix(s).exists() for s in m.SUFFIXES))

    def test_publish_conflict_keeps_unrelated_outputs(self):
        staged = self.staged_candidate()
        foreign = self.args.output_app.with_suffix(m.SUFFIXES[1])
        foreign.write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'appeared'):
            m.publish_candidate(staged, self.args.output_app, lambda *args: self.fail('must not publish'))
        self.assertEqual(foreign.read_text(), 'foreign')

    def test_publish_rollback_preserves_replaced_sidecar_inode(self):
        staged = self.staged_candidate()
        foreign = self.args.output_app.with_suffix(m.SUFFIXES[0])
        def replace_and_fail(source, dest):
            foreign.unlink()
            foreign.write_text('foreign replaced inode')
            raise OSError('failure')
        with self.assertRaises(OSError):
            m.publish_candidate(staged, self.args.output_app, replace_and_fail)
        self.assertEqual(foreign.read_text(), 'foreign replaced inode')

    def test_missing_framework_metadata_fails_without_touching_source(self):
        self.library('Freetype.framework/Versions/A/Freetype')
        plan = m.library_plan(self.inputs, self.lock)
        before = m.app_tree(self.app)
        self.args.log_dir.mkdir()
        with patch.object(m, 'run_step'), self.assertRaisesRegex(ValueError, 'framework metadata'):
            m.embed_runtime(self.args, self.root / 'Runtime.app', plan, self.builder)
        self.assertEqual(m.app_tree(self.app), before)

    def test_embedded_signature_failure_does_not_resign(self):
        self.args.log_dir.mkdir()
        plan = m.library_plan(self.inputs, self.lock)
        before = m.app_tree(self.app)
        calls = []
        def signature_failure(command, log):
            calls.append(command)
            raise ValueError('signature rejected')
        with patch.object(m, 'run_step', side_effect=signature_failure), self.assertRaisesRegex(ValueError, 'signature rejected'):
            m.embed_runtime(self.args, self.root / 'Runtime.app', plan, self.builder)
        self.assertEqual(m.app_tree(self.app), before)
        self.assertEqual(calls[0][0:3], ['codesign', '--verify', '--strict'])
        self.assertNotIn('--force', calls[0])

    def envelope_fixture(self, fault=None):
        self.args.log_dir.mkdir()
        plan = m.library_plan(self.inputs, self.lock)
        stage = self.root / 'Runtime.app'
        shutil.copytree(self.app, stage)
        target = stage / 'Contents/Frameworks/libass.dylib'
        shutil.copy2(self.inputs / 'lib/libass.dylib', target)
        self.builder.library_identity = lambda path, arch: {
            'install_dependencies': ['@rpath/libass.dylib']}
        after_sign = False
        calls = []
        source_before = m.app_tree(self.app)
        def output(command):
            shutil.copy2(command[1], command[-1])
            if after_sign and fault == 'thin':
                Path(command[-1]).write_bytes(b'changed thin identity')
            return ''
        self.builder.output = output
        def signature(path, arch, builder, context):
            self.assertEqual(context, target)
            return {'signed': fault != 'unsigned', 'lc_code_signature': True,
                    'cdhash': ('different' if after_sign and fault == 'cdhash' else m.sha(path)[:40]),
                    'strict_verify_exit': 0}
        preparer = types.SimpleNamespace(signature_state=signature)
        def run(command, log):
            nonlocal after_sign
            calls.append(command)
            self.assertEqual(command[0], 'codesign')
            self.assertEqual(command[-1], stage)
            if '--sign' in command:
                self.assertNotIn('--deep', command)
                self.assertIn('--preserve-metadata=entitlements,requirements,flags', command)
                if fault == 'sign':
                    raise ValueError('sign failed')
                after_sign = True
                if fault == 'whole':
                    target.write_bytes(b'changed locked bytes')
                if fault == 'source':
                    (self.app / 'Contents/Resources/file').write_text('external change')
            else:
                self.assertEqual(command[:4], ['codesign', '--verify', '--deep', '--strict'])
                if fault == 'verify':
                    raise ValueError('verify failed')
            log.write_text('mock native envelope boundary')
            return {'exit_code': 0}
        with patch.object(m, 'run_step', side_effect=run):
            if fault:
                with self.assertRaises(ValueError):
                    m.sign_runtime_envelope(self.args, stage, plan, self.builder, preparer)
                self.assertFalse((self.args.log_dir / 'runtime-envelope.json').exists())
            else:
                record = m.sign_runtime_envelope(self.args, stage, plan, self.builder, preparer)
                self.assertEqual(record['before'], record['after'])
                self.assertEqual(len(record['before']['@rpath/libass.dylib']['architectures']), 2)
                self.assertTrue((self.args.log_dir / 'runtime-envelope.json').is_file())
                self.assertEqual(len(calls), 2)
        if fault != 'source':
            self.assertEqual(m.app_tree(self.app), source_before)
        self.assertFalse(self.args.output_app.exists())
        if fault == 'unsigned':
            self.assertEqual(calls, [])

    def test_runtime_envelope_signs_only_app_preserving_library_identities(self):
        self.envelope_fixture()

    def test_runtime_envelope_unsigned_library_rejects_before_signing(self):
        self.envelope_fixture('unsigned')

    def test_runtime_envelope_signature_failure_rejects(self): self.envelope_fixture('sign')
    def test_runtime_envelope_deep_verify_failure_rejects(self): self.envelope_fixture('verify')
    def test_runtime_envelope_whole_hash_change_rejects(self): self.envelope_fixture('whole')
    def test_runtime_envelope_thin_hash_change_rejects(self): self.envelope_fixture('thin')
    def test_runtime_envelope_cdhash_change_rejects(self): self.envelope_fixture('cdhash')
    def test_runtime_envelope_source_drift_rejects(self): self.envelope_fixture('source')

    def test_embedded_hash_after_packaging_detects_resigning(self):
        plan = m.library_plan(self.inputs, self.lock)
        stage = self.root / 'Runtime.app'
        shutil.copytree(self.app, stage)
        target = stage / 'Contents/Frameworks/libass.dylib'
        target.write_bytes((self.inputs / 'lib/libass.dylib').read_bytes() + b'new signature')
        with self.assertRaisesRegex(ValueError, 'whole-file SHA differs'):
            m.verify_embedded(stage, plan, self.builder)

    def write_build_state(self):
        self.args.work_dir.mkdir()
        self.args.published_dir.mkdir()
        (self.inputs / 'archive').mkdir()
        (self.inputs / 'archive/mpv.tar.gz').write_text('source archive')
        identity = {'archive': str(self.inputs / 'archive/mpv.tar.gz'),
            'archive_sha256': m.sha(self.inputs / 'archive/mpv.tar.gz'),
            'work_dir': str(self.args.work_dir), 'output_dir': str(self.args.published_dir),
            'architectures': list(m.ARCHES), 'jobs': 4, 'options': self.builder.OPTIONS,
            'dependencies': self.lock,
            **{key: m.sha(self.recipe / name) for name, key in m.RECIPE_KEYS.items()}}
        package = {'build_identity_sha256': m.canonical(identity),
                   'source': {'source_tree_sha256': 'full-tree'}, 'architectures': list(m.ARCHES),
                   'files': {'arm64/libmpv.2.dylib': 'slice'}}
        state = {'identity': identity, 'verified_source': package['source'], 'publication': package}
        (self.args.work_dir / 'build-state.json').write_text(json.dumps(state))
        (self.args.published_dir / 'slice-manifest.json').write_text(json.dumps(package))
        return state

    def test_complete_build_identity_matches(self):
        self.write_build_state()
        m.validate_build(self.args, {'lock': self.lock}, self.builder)

    def test_build_state_rejects_another_inputs_lock(self):
        self.write_build_state()
        other = json.loads(json.dumps(self.lock))
        other['extra'] = 'another execution identity'
        with self.assertRaisesRegex(ValueError, 'dependencies'):
            m.validate_build(self.args, {'lock': other}, self.builder)

    def test_build_state_rejects_full_source_or_published_file_drift(self):
        self.write_build_state()
        self.builder.verify_source = lambda *args: {'source_tree_sha256': 'changed'}
        with self.assertRaisesRegex(ValueError, 'complete source'):
            m.validate_build(self.args, {'lock': self.lock}, self.builder)
        self.builder.verify_source = lambda *args: {'source_tree_sha256': 'full-tree'}
        self.builder.publication_files = lambda *args: {'extra': 'file'}
        with self.assertRaisesRegex(ValueError, 'file set or SHA'):
            m.validate_build(self.args, {'lock': self.lock}, self.builder)

    def execute_fixture(self, fault=None, check_inputs=False):
        calls = []
        before = m.app_tree(self.app)
        self.args.check_inputs = check_inputs
        verified = {'manifest_sha256': 'sealed-manifest', 'manifest': {}, 'lock': self.lock}
        preparer = types.SimpleNamespace(publish_absent=lambda src, dst: src.rename(dst),
            signature_state=lambda path, arch, builder, context: {
                'signed': True, 'lc_code_signature': True, 'cdhash': m.sha(path)[:40],
                'strict_verify_exit': 0})
        def tool_output(command):
            if str(command[0]) != 'lipo':
                self.fail('unexpected native tool boundary')
            shutil.copy2(command[1], command[-1])
            return ''
        self.builder.output = tool_output
        self.builder.library_identity = lambda path, arch: {
            'install_dependencies': ['@rpath/' + path.relative_to(path.parents[0]).as_posix()]}
        def verify(args, name):
            calls.append(name)
            if fault == 'final-inputs' and name == 'inputs-after-package':
                return {**verified, 'manifest_sha256': 'externally changed'}
            return verified
        def run(command, log):
            log.write_text('mock tool boundary')
            command = [str(p) for p in command]
            if command[:3] == ['codesign', '--force', '--sign'] and fault == 'envelope':
                raise ValueError('injected envelope signature failure')
            if 'package_macos_shared_build.py' in command[1]:
                calls.append('package-gates')
                runtime, staged = Path(command[2]), Path(command[3])
                shutil.copytree(runtime, staged, symlinks=True)
                for suffix in m.SUFFIXES:
                    staged.with_suffix(suffix).write_text('{}')
                if fault == 'pending':
                    info = staged / 'Contents/Info.plist'
                    values = plistlib.loads(info.read_bytes())
                    values['MediaKitSharedBootstrapPending'] = False
                    info.write_bytes(plistlib.dumps(values))
                if fault == 'package':
                    raise ValueError('injected package failure')
                if fault == 'final-source':
                    (self.app / 'Contents/Resources/file').write_text('external change')
            elif command[0].endswith('verify_macos_mpv_bundle.sh'):
                calls.append('final-bundle-gates')
                if fault == 'final-gate':
                    raise ValueError('injected final bundle gate failure')
            elif len(command) > 1 and command[1].endswith('/build_macos.py'):
                calls.append('build')
            return {'exit_code': 0}
        original_publish = m.publish_candidate
        def publish(staged, output, publisher):
            calls.append('publish')
            self.assertEqual(calls[-4:-1], ['package-gates', 'final-bundle-gates', 'inputs-after-package'])
            self.assertFalse(output.exists())
            original_publish(staged, output, publisher)
        def modules(path, name):
            return preparer if name == 'candidate_preparer' else self.builder
        with patch.object(m, 'load_module', side_effect=modules), \
             patch.object(m, 'validate_input_app', return_value={'static': 'mock-only'}), \
             patch.object(m, 'verify_inputs', side_effect=verify), \
             patch.object(m, 'validate_build', return_value={'identity': {'dependencies': self.lock}}), \
             patch.object(m, 'run_step', side_effect=run), \
             patch.object(m, 'publish_candidate', side_effect=publish):
            if fault:
                with self.assertRaises(ValueError):
                    m.execute(self.args)
            else:
                result = m.execute(self.args)
                self.assertEqual(result['status'], 'inputs-checked-only' if check_inputs else 'published-candidate')
        if fault:
            self.assertFalse(self.args.output_app.exists())
            self.assertFalse(any(self.args.output_app.with_suffix(s).exists() for s in m.SUFFIXES))
            self.assertNotIn('publish', calls)
        if fault != 'final-source':
            self.assertEqual(m.app_tree(self.app), before)
        else:
            self.assertEqual((self.app / 'Contents/Resources/file').read_text(), 'external change')
        self.assertFalse(list(self.root.glob('.Candidate.consumer-*')))
        self.assertTrue((self.args.log_dir / 'result.json').is_file())
        return calls

    def test_execute_all_gates_before_exclusive_publication(self):
        calls = self.execute_fixture()
        self.assertEqual([c for c in calls if c.startswith('inputs-')],
                         ['inputs-before-build', 'inputs-before-package', 'inputs-after-package'])
        self.assertLess(calls.index('build'), calls.index('package-gates'))
        self.assertEqual(calls[-1], 'publish')

    def test_execute_pending_presence_blocks_final_publication_even_false(self):
        self.execute_fixture('pending')

    def test_execute_envelope_failure_cleans_private_stage_without_publish(self):
        self.execute_fixture('envelope')

    def test_execute_package_failure_cleans_private_stage_only(self):
        self.execute_fixture('package')

    def test_execute_final_bundle_gate_failure_has_no_candidate(self):
        self.execute_fixture('final-gate')

    def test_execute_final_inputs_drift_has_no_candidate(self):
        self.execute_fixture('final-inputs')

    def test_execute_final_source_drift_is_reported_not_deleted(self):
        self.execute_fixture('final-source')

    def test_execute_check_inputs_never_builds_packages_or_publishes(self):
        calls = self.execute_fixture(check_inputs=True)
        self.assertEqual(calls, ['inputs-before-build'])

    def test_sidecar_conflict_after_first_link_rolls_back_only_own_link(self):
        staged = self.staged_candidate()
        real_link = os.link
        foreign = self.args.output_app.with_suffix(m.SUFFIXES[1])
        def link(source, dest):
            real_link(source, dest)
            if dest == self.args.output_app.with_suffix(m.SUFFIXES[0]):
                foreign.write_text('foreign raced after preflight')
        with patch.object(m.os, 'link', side_effect=link), self.assertRaises(FileExistsError):
            m.publish_candidate(staged, self.args.output_app, lambda *args: self.fail('must not rename'))
        self.assertFalse(self.args.output_app.with_suffix(m.SUFFIXES[0]).exists())
        self.assertEqual(foreign.read_text(), 'foreign raced after preflight')



if __name__ == '__main__':
    unittest.main()
