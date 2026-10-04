import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/fetch_macos_shared_ci_inputs.py'
spec = importlib.util.spec_from_file_location('ci_inputs', SCRIPT)
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


def thin(cpu=0x100000C, signed=True, code=b'ABCD', uuid=b'U' * 16, minos=12 << 16):
    def dylib(cmd, name):
        value = name.encode() + b'\0'
        size = (24 + len(value) + 7) // 8 * 8
        return struct.pack('<6I', cmd, size, 24, 0, 0, 0) + value + b'\0' * (size - 24 - len(value))
    text = struct.pack('<II16s4Q4I', 0x19, 152, b'__TEXT', 0, 1024, 0, 1024, 5, 5, 1, 0)
    text += struct.pack('<16s16sQQ8I', b'__text', b'__TEXT', 768, len(code), 768, 2, 0, 0, 0, 0, 0, 0)
    linkedit = struct.pack('<II16s4Q4I', 0x19, 72, b'__LINKEDIT', 1024, 4096 if signed else 0,
                           1024, 32 if signed else 0, 1, 1, 0, 0)
    commands = [text, linkedit, struct.pack('<6I', 0x32, 24, 1, minos, 0, 0),
                struct.pack('<II16s', 0x1B, 24, uuid),
                dylib(0xD, '@rpath/Ass.framework/Versions/A/Ass'),
                dylib(0xC, '/usr/lib/libSystem.B.dylib')]
    if signed:
        commands.append(struct.pack('<4I', 0x1D, 16, 1024, 32))
    header = struct.pack('<8I', 0xFEEDFACF, cpu, 0, 6, len(commands), sum(map(len, commands)), 0, 0)
    data = bytearray(header + b''.join(commands))
    data.extend(b'\0' * (1024 - len(data)))
    data[768:768 + len(code)] = code
    if signed:
        data.extend(b'S' * 32)
    return bytes(data)


def zip_fixture(name='Ass', *, link=None, platform='macos', code=b'raw:Ass'):
    data = io.BytesIO()
    root = name + '.xcframework/'
    info = {'AvailableLibraries': [{'SupportedPlatform': platform,
        'SupportedArchitectures': ['arm64', 'x86_64'],
        'LibraryIdentifier': 'macos-arm64_x86_64', 'LibraryPath': name + '.framework'}]}
    prefix = root + 'macos-arm64_x86_64/' + name + '.framework/'
    with zipfile.ZipFile(data, 'w') as z:
        z.writestr(root + 'Info.plist', plistlib.dumps(info))
        z.writestr(prefix + 'Versions/A/' + name, code)
        z.writestr(prefix + 'Versions/A/Resources/Info.plist', plistlib.dumps({'CFBundleExecutable': name}))
        for path, target in [('Versions/Current', 'A'), (name, 'Versions/Current/' + name),
                             ('Resources', 'Versions/Current/Resources')]:
            entry = zipfile.ZipInfo(prefix + path)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(entry, target)
        if link:
            entry = zipfile.ZipInfo(prefix + 'unsafe')
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(entry, link)
    return data.getvalue()


def tar_fixture(data=b'header', *, name='uchardet-0.0.8/src/uchardet.h', link=False):
    value = io.BytesIO()
    with tarfile.open(fileobj=value, mode='w:xz') as tar:
        member = tarfile.TarInfo(name)
        if link:
            member.type, member.linkname = tarfile.SYMTYPE, '/etc/passwd'
            tar.addfile(member)
        else:
            member.size = len(data)
            tar.addfile(member, io.BytesIO(data))
    return value.getvalue()


class FakeTools:
    fail_xcode = False
    corrupt_code = False
    fail_final = False
    events = []

    def __init__(self, logs):
        self.logs = logs

    def run(self, argv, *, required=True):
        argv = [str(p) for p in argv]
        self.events.append(argv)
        tool = Path(argv[0]).name
        stdout, stderr, exit_code = '', '', 0
        if tool == 'xcodebuild' and '-version' in argv:
            stdout = 'Xcode fixture\nBuild version fixture\n'
        elif tool == 'xcode-select':
            stdout = '/fixture/Xcode/Developer\n'
        elif tool == 'xcrun':
            stdout = '/fixture/SDK\n' if '--show-sdk-path' in argv else 'fixture\n'
        elif tool == 'lipo' and '-archs' in argv:
            stdout = 'arm64 x86_64\n'
        elif tool == 'lipo':
            source, arch = Path(argv[1]), argv[3]
            signed = source.read_bytes().startswith(b'signed:') or arch == 'arm64'
            code = b'DIFF' if b'corrupt' in source.read_bytes() else b'ABCD'
            value = thin(0x100000C if arch == 'arm64' else 0x1000007, signed, code)
            name = source.name.encode()
            # Every framework has its own correct immutable ID.
            original = b'@rpath/Ass.framework/Versions/A/Ass'
            expected = b'@rpath/' + name + b'.framework/Versions/A/' + name
            # Ass is used as the synthetic Mach-O type contract; actual ID
            # checks are injected below for other names, without claiming bytes.
            Path(argv[-1]).write_bytes(value)
        elif tool == 'otool':
            source, arch = Path(argv[-1]), argv[2]
            stdout = 'cmd LC_CODE_SIGNATURE\n' if source.read_bytes().startswith(b'signed:') or arch == 'arm64' else ''
        elif tool == 'codesign' and '--display' in argv:
            source, arch = Path(argv[-1]), argv[argv.index('--arch') + 1]
            if source.read_bytes().startswith(b'signed:'):
                stderr = 'CodeDirectory flags=0x2(adhoc)\nCDHash=' + 'a' * 40 + '\n'
            elif arch == 'arm64':
                stderr = 'CodeDirectory flags=0x20002(adhoc,linker-signed)\nInfo.plist=not bound\nSealed Resources=none\nCDHash=' + 'b' * 40 + '\n'
            else:
                exit_code, stderr = 1, 'code object is not signed at all\n'
        elif tool == 'codesign':
            source = Path(argv[-1])
            if source.is_dir():
                binary = source / 'Versions/A' / source.stem
                signed = binary.read_bytes().startswith(b'signed:')
                if not signed:
                    arch = argv[argv.index('--arch') + 1]
                    exit_code = 1
                    stderr = ('code has no resources but signature indicates they must be present\n'
                              if arch == 'arm64' else 'code object is not signed at all\n')
                if self.fail_final and 'signed' in source.parts:
                    exit_code, stderr = 1, 'invalid final fixture signature\n'
            else:
                if b'S' * 32 not in source.read_bytes():
                    exit_code, stderr = 1, 'code object is not signed at all\n'
        elif tool == 'xcodebuild':
            if self.fail_xcode:
                raise ValueError('mock Xcode failure')
            project = Path(argv[argv.index('-project') + 1])
            tmp = project.parents[1]
            built = Path(next(p.split('=', 1)[1] for p in argv if p.startswith('CONFIGURATION_BUILD_DIR=')))
            for name in ci.FRAMEWORKS:
                source = tmp / 'host-inputs' / (name + '.framework')
                target = built / 'FrameworkSigningHost.app/Contents/Frameworks' / source.name
                shutil.copytree(source, target, symlinks=True)
                binary = target / 'Versions/A' / name
                if not binary.read_bytes().startswith(b'signed:'):
                    binary.write_bytes(b'signed:' + (b'corrupt' if self.corrupt_code else b'') + binary.read_bytes())
                    signature = target / 'Versions/A/_CodeSignature'
                    signature.mkdir()
                    (signature / 'CodeResources').write_text('mock resources')
        else:
            raise AssertionError(argv)
        result = {'argv': argv, 'stdout': stdout, 'stderr': stderr, 'exit_code': exit_code}
        if required and exit_code:
            raise ValueError('mock required tool failure')
        return result


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ci-input-test-')
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.temporary.cleanup)
        self.output, self.logs = self.root / 'raw', self.root / 'fetch-logs'
        self.lock = ci.load_lock()
        self.payloads = {name: (zip_fixture(name, code=('raw:' + name).encode())
                              if name in ci.FRAMEWORKS else b'fixed-' + name.encode())
                         for name in self.lock['artifacts']}
        self.payloads['uchardet'] = tar_fixture()
        for name, value in self.payloads.items():
            self.lock['artifacts'][name]['sha256'] = hashlib.sha256(value).hexdigest()
        self.lock['header']['sha256'] = hashlib.sha256(b'header').hexdigest()

    def fake_download(self, entry, path, hosts):
        name = next(k for k, v in self.lock['artifacts'].items() if v is entry)
        path.write_bytes(self.payloads[name])
        return {'url': entry['url'], 'final_url': entry['url'], 'filename': entry['filename'],
                'sha256': entry['sha256'], 'bytes': len(self.payloads[name])}

    def acquire(self):
        with patch.object(ci, 'load_lock', return_value=self.lock), patch.object(ci, 'download', self.fake_download):
            return ci.fetch(self.output, self.logs)

    def verify(self):
        with patch.object(ci, 'load_lock', return_value=self.lock):
            return ci.verify(self.output)

    def test_fixed_lock_and_host_files(self):
        self.assertEqual(set(ci.load_lock()['artifacts']), set(self.payloads))

    def test_fetch_and_rederive_success(self):
        result = self.acquire()
        self.assertEqual(result['status'], 'published-raw-dependencies')
        self.assertEqual(self.verify()['kind'], 'authenticated-raw-dependencies')
        self.assertEqual((self.output / 'frameworks/Ass.framework/Ass').resolve().read_bytes(), b'raw:Ass')

    def test_cli_has_no_url_or_hash_override(self):
        with self.assertRaises(SystemExit):
            ci.main(['fetch', '--output', str(self.output), '--log-dir', str(self.logs), '--url', 'https://evil.invalid'])

    def test_existing_outputs_rejected(self):
        self.output.mkdir()
        with self.assertRaises(ValueError):
            self.acquire()
        self.assertFalse(self.logs.exists())

    def test_repository_output_rejected(self):
        with self.assertRaises(ValueError):
            ci.output_paths(ci.HERE / 'unowned-test-output', self.logs)

    def test_overlapping_paths_rejected(self):
        with self.assertRaises(ValueError):
            ci.output_paths(self.output, self.output / 'logs')

    def test_noncanonical_and_symlink_path_rejected(self):
        for path in (self.root / 'raw/../escaped',):
            with self.assertRaises(ValueError):
                ci.checked_path(path, exists=False)
        (self.root / 'alias').symlink_to(self.root)
        with self.assertRaises(ValueError):
            ci.checked_path(self.root / 'alias/new', exists=False)

    def test_fixed_header_mismatch_no_publish(self):
        self.lock['header']['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            self.acquire()
        self.assertFalse(self.output.exists())
        self.assertEqual(json.loads((self.logs / 'result.json').read_text())['status'], 'failed')

    def test_fetch_failure_no_partial_publication(self):
        with patch.object(ci, 'load_lock', return_value=self.lock), patch.object(ci, 'download', side_effect=ValueError('download failed')):
            with self.assertRaises(ValueError):
                ci.fetch(self.output, self.logs)
        self.assertFalse(self.output.exists())

    def test_framework_platform_rejected(self):
        path = self.root / 'wrong.zip'
        path.write_bytes(zip_fixture(platform='ios'))
        with self.assertRaises(ValueError):
            ci.extract_framework(path, self.root / 'wrong.framework', self.lock['artifacts']['Ass'], 'Ass')

    def test_zip_links_escape_or_dangling_rejected(self):
        for index, link in enumerate(('/etc/passwd', '../../../../escape', 'missing')):
            path = self.root / f'link{index}.zip'
            path.write_bytes(zip_fixture(link=link))
            with self.assertRaises(ValueError):
                ci.extract_framework(path, self.root / f'link{index}.framework', self.lock['artifacts']['Ass'], 'Ass')

    def test_tar_traversal_link_and_missing_header_rejected(self):
        for index, value in enumerate((tar_fixture(name='../escape'), tar_fixture(link=True), tar_fixture(name='other'))):
            path = self.root / f'bad{index}.tar.xz'
            path.write_bytes(value)
            with self.assertRaises(ValueError):
                ci.extract_header(path, self.root / 'header', self.lock['header'])

    def test_zip_duplicate_and_special_files_rejected(self):
        for special in (False, True):
            value = io.BytesIO()
            with zipfile.ZipFile(value, 'w') as z:
                if special:
                    entry = zipfile.ZipInfo('fifo')
                    entry.external_attr = (stat.S_IFIFO | 0o644) << 16
                    z.writestr(entry, b'')
                else:
                    z.writestr('same', b'a')
                    z.writestr('same', b'b')
            with zipfile.ZipFile(io.BytesIO(value.getvalue())) as z:
                with self.assertRaises(ValueError):
                    ci.zip_entries(z, 1024)

    def test_resealed_framework_cannot_escape_zip_proof(self):
        self.acquire()
        binary = self.output / 'frameworks/Ass.framework/Versions/A/Ass'
        binary.write_bytes(b'changed')
        manifest_path = self.output / ci.MANIFEST
        manifest = json.loads(manifest_path.read_text())
        manifest['files'] = ci.tree(self.output, exclude=(ci.MANIFEST,))
        manifest['frameworks']['Ass']['tree'] = ci.tree(binary.parents[2])
        manifest['frameworks']['Ass']['tree_sha256'] = ci.canonical(manifest['frameworks']['Ass']['tree'])
        manifest['frameworks']['Ass']['binary_sha256'] = ci.sha(binary)
        ci.write_json(manifest_path, manifest)
        with self.assertRaises(ValueError):
            self.verify()

    def test_extra_file_or_manifest_link_rejected(self):
        self.acquire()
        (self.output / 'extra').write_text('unknown')
        with self.assertRaises(ValueError):
            self.verify()
        (self.output / 'extra').unlink()
        manifest = self.output / ci.MANIFEST
        moved = self.root / 'manifest.json'
        manifest.rename(moved)
        manifest.symlink_to(moved)
        with self.assertRaises(ValueError):
            self.verify()

    def signing_patches(self):
        original = ci.macho_payload
        def payload(data):
            value = original(data)
            # Fake tool emits Ass fixture ID; map to current framework from its
            # most recent lipo argv. No real ABI evidence is claimed by this mock.
            argv = next(v for v in reversed(FakeTools.events) if Path(v[0]).name == 'lipo' and '-thin' in v)
            name = Path(argv[1]).name
            value['install_id'] = f'@rpath/{name}.framework/Versions/A/{name}'
            return value
        return (patch.object(ci, 'load_lock', return_value=self.lock),
                patch.object(ci, 'ToolRunner', FakeTools), patch.object(ci, 'macho_payload', side_effect=payload))

    def sign(self):
        output, logs = self.root / 'signed', self.root / 'sign-logs'
        p1, p2, p3 = self.signing_patches()
        with p1, p2, p3:
            result = ci.signing_contexts(self.output, output, logs)
        return result, output, logs

    def test_mock_complete_signing_and_final_path_seal(self):
        self.acquire()
        before = ci.tree(self.output)
        FakeTools.events, FakeTools.fail_xcode, FakeTools.corrupt_code, FakeTools.fail_final = [], False, False, False
        result, signed, logs = self.sign()
        self.assertEqual(result['status'], 'published-signed-contexts')
        self.assertEqual(ci.tree(self.output), before)
        p1, p2, p3 = self.signing_patches()
        with p1, p2, p3:
            checked = ci.verify_contexts(self.output, signed, FakeTools(logs))
        self.assertEqual(checked['policy'], 'valid-complete-preserved-or-verified-linker-code-bundle-sign-v1')
        commands = FakeTools.events
        xcode = next(i for i, v in enumerate(commands) if Path(v[0]).name == 'xcodebuild' and '-project' in v)
        self.assertTrue(any(Path(v[0]).name == 'codesign' for v in commands[:xcode]))
        self.assertTrue(any(str(signed) in v[-1] for v in commands[xcode + 1:] if Path(v[0]).name == 'codesign'))
        host_argv = commands[xcode]
        for setting in ('COPY_PHASE_STRIP', 'DEPLOYMENT_POSTPROCESSING', 'STRIP_INSTALLED_PRODUCT'):
            self.assertEqual([v for v in host_argv if v.startswith(setting + '=')], [setting + '=NO'])
        for name in ci.FRAMEWORKS:
            audit = json.loads((logs / ('derivation-' + name + '.json')).read_text())
            self.assertEqual(audit['payload_diff'], {arch: [] for arch in ci.ARCHES})
            self.assertEqual(audit['resource_diff'], [])

    def test_mock_xcode_failure_no_output_source_unchanged(self):
        self.acquire()
        before = ci.tree(self.output)
        FakeTools.events, FakeTools.fail_xcode, FakeTools.corrupt_code, FakeTools.fail_final = [], True, False, False
        with self.assertRaises(ValueError):
            self.sign()
        self.assertFalse((self.root / 'signed').exists())
        self.assertEqual(ci.tree(self.output), before)

    def test_mock_changed_code_rejected(self):
        self.acquire()
        FakeTools.events, FakeTools.fail_xcode, FakeTools.corrupt_code, FakeTools.fail_final = [], False, True, False
        before = ci.tree(self.output)
        with self.assertRaisesRegex(ValueError, 'code payload'):
            self.sign()
        self.assertFalse((self.root / 'signed').exists())
        self.assertEqual(ci.tree(self.output), before)
        logs = self.root / 'sign-logs'
        self.assertEqual(json.loads((logs / 'result.json').read_text())['status'], 'failed')
        source = json.loads((logs / 'source-inspection.json').read_text())
        self.assertEqual(set(source), set(ci.FRAMEWORKS))
        # Private build/stage cleanup must not erase any of the five comparisons.
        self.assertFalse(list(self.root.glob('.shared-ci-sign-*')))
        for name in ci.FRAMEWORKS:
            audit = json.loads((logs / ('derivation-' + name + '.json')).read_text())
            self.assertEqual(audit['framework'], name)
            for arch in ci.ARCHES:
                self.assertNotEqual(audit['before']['architectures'][arch]['payload'],
                                    audit['after']['architectures'][arch]['payload'])
                self.assertTrue(any(row['path'] == '/sections/0/sha256'
                                    for row in audit['payload_diff'][arch]))
                self.assertIn('commands', audit['after']['architectures'][arch]['payload'])
                self.assertIn('linkedit', audit['after']['architectures'][arch]['payload'])

    def test_mock_final_signature_failure_rolls_back_own_output(self):
        self.acquire()
        FakeTools.events, FakeTools.fail_xcode, FakeTools.corrupt_code, FakeTools.fail_final = [], False, False, True
        with self.assertRaises(ValueError):
            self.sign()
        self.assertFalse((self.root / 'signed').exists())


class SignatureAndPayloadTests(unittest.TestCase):
    def test_linker_signature_exception_is_narrow(self):
        display = {'exit_code': 0, 'stdout': '', 'stderr': 'flags=0x20002(adhoc,linker-signed)\nInfo.plist=not bound\nSealed Resources=none\nCDHash=' + 'b' * 40 + '\n'}
        context = {'exit_code': 1, 'stderr': 'code has no resources but signature indicates they must be present'}
        isolated = {'exit_code': 0, 'stderr': ''}
        self.assertEqual(ci.source_classification(True, display, context, isolated)['class'],
                         'valid-linker-code-without-bundle-resources')
        for modified in (display['stderr'].replace('linker-signed', 'other'),
                         display['stderr'].replace('not bound', 'bound'),
                         display['stderr'].replace('Resources=none', 'Resources=version 2'),
                         display['stderr'].replace('0x20002', '0x2')):
            with self.assertRaises(ValueError):
                ci.source_classification(True, dict(display, stderr=modified), context, isolated)
        with self.assertRaises(ValueError):
            ci.source_classification(True, display, context, {'exit_code': 1, 'stderr': 'invalid code'})

    def test_unsigned_needs_two_evidence_sources(self):
        display = {'exit_code': 1, 'stdout': '', 'stderr': 'not signed at all'}
        context = {'exit_code': 1, 'stderr': 'not signed at all'}
        self.assertEqual(ci.source_classification(False, display, context, context)['class'], 'unsigned-code')
        with self.assertRaises(ValueError):
            ci.source_classification(False, display, context, {'exit_code': 0, 'stderr': ''})

    def test_complete_signature_preserved(self):
        display = {'exit_code': 0, 'stdout': '', 'stderr': 'CDHash=' + 'a' * 40 + '\n'}
        valid = {'exit_code': 0, 'stderr': ''}
        self.assertEqual(ci.source_classification(True, display, valid, valid)['class'], 'valid-complete-context')
        self.assertEqual(ci.source_classification(True, display, valid,
            {'exit_code': 1, 'stderr': 'isolated bundle metadata unavailable'})['class'], 'valid-complete-context')
        with self.assertRaises(ValueError):
            ci.source_classification(False, display, valid, valid)

    def test_payload_allows_only_signing_metadata_changes(self):
        self.assertEqual(ci.macho_payload(thin(signed=False)), ci.macho_payload(thin(signed=True)))
        self.assertNotEqual(ci.macho_payload(thin()), ci.macho_payload(thin(code=b'DIFF')))
        self.assertNotEqual(ci.macho_payload(thin()), ci.macho_payload(thin(uuid=b'X' * 16)))
        self.assertNotEqual(ci.macho_payload(thin()), ci.macho_payload(thin(minos=13 << 16)))

    def test_payload_bounds_rejected(self):
        for value in (b'bad', thin()[:100], thin()[:770]):
            with self.assertRaises(ValueError):
                ci.macho_payload(value)

    def test_metadata_resource_change_rejected(self):
        before = {'preserve_complete_context': False, 'tree': {'Resources': {'type': 'file', 'sha256': 'a'}},
                  'architectures': {a: {'payload': {}} for a in ci.ARCHES}}
        after = copy.deepcopy(before)
        after['preserve_complete_context'] = True
        after['tree']['Resources']['sha256'] = 'b'
        with self.assertRaisesRegex(ValueError, 'metadata/resources'):
            ci.validate_derivation(before, after, 'Ass')

    def test_unrelated_signature_named_resource_is_covered(self):
        captured = {'other/_CodeSignature/resource': {'sha256': 'a'},
                    'Versions/A/_CodeSignature/CodeResources': {'sha256': 'b'}}
        result = ci.resource_identity(captured, 'Ass')
        self.assertIn('other/_CodeSignature/resource', result)
        self.assertNotIn('Versions/A/_CodeSignature/CodeResources', result)

    def test_valid_complete_context_cannot_be_resigned(self):
        before = {'preserve_complete_context': True, 'tree': {},
                  'architectures': {a: {'payload': {}, 'thin_sha256': 'a'} for a in ci.ARCHES}}
        after = copy.deepcopy(before)
        after['architectures']['arm64']['thin_sha256'] = 'b'
        with self.assertRaisesRegex(ValueError, 're-signed'):
            ci.validate_derivation(before, after, 'Ass')

    def test_host_preserves_already_signed_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = ci.render_host(Path(tmp) / 'host', Path('/fixed/frameworks'),
                                     {n: True for n in ci.FRAMEWORKS})
            self.assertNotIn('CodeSignOnCopy,', (project / 'project.pbxproj').read_text())

    def test_host_explicitly_disables_copy_and_deployment_stripping(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = ci.render_host(Path(tmp) / 'host', Path('/fixed/frameworks'),
                                     {n: False for n in ci.FRAMEWORKS})
            template = (project / 'project.pbxproj').read_text()
            for setting in ('COPY_PHASE_STRIP', 'DEPLOYMENT_POSTPROCESSING', 'STRIP_INSTALLED_PRODUCT'):
                self.assertEqual(template.count(setting + ' = NO;'), 1)
                self.assertNotIn(setting + ' = YES;', template)
            self.assertEqual(template.count('CodeSignOnCopy,'), len(ci.FRAMEWORKS))

    def test_symtab_string_growth_remains_a_payload_violation(self):
        def symbols(strsize):
            data = bytearray(thin(signed=False))
            header = list(struct.unpack_from('<8I', data))
            offset = 32 + header[5]
            data[offset:offset + 24] = struct.pack('<6I', 2, 24, 1024, 1, 1040, strsize)
            header[4] += 1; header[5] += 24
            struct.pack_into('<8I', data, 0, *header)
            data.extend(b'S' * 16 + b'\0' * 64)
            return ci.macho_payload(bytes(data))
        first, grown = symbols(32), symbols(40)
        self.assertNotEqual(first, grown)
        self.assertTrue(any(v['path'] == '/linkedit/1/size' and v['before'] == 32 and v['after'] == 40
                            for v in ci.structural_diff(first, grown)))
        before = {'preserve_complete_context': False, 'tree': {},
                  'architectures': {arch: {'payload': first} for arch in ci.ARCHES}}
        after = copy.deepcopy(before); after['preserve_complete_context'] = True
        after['architectures']['arm64']['payload'] = grown
        with self.assertRaisesRegex(ValueError, 'code payload'):
            ci.validate_derivation(before, after, 'Ass')

    def test_structural_diff_reports_missing_fields_and_list_items(self):
        rows = ci.structural_diff({'a': [1, 2], 'b': None}, {'a': [1], 'c': None})
        paths = {row['path']: row for row in rows}
        self.assertEqual(paths['/a/1']['before'], 2)
        self.assertFalse(paths['/a/1']['after_present'])
        self.assertTrue(paths['/b']['before_present'])
        self.assertFalse(paths['/b']['after_present'])
        self.assertTrue(paths['/c']['after_present'])

    def test_redirects_are_https_allowlist_only(self):
        hosts = ci.load_lock()['redirect_hosts']
        for url in ('http://github.com/file', 'https://evil.invalid/file', 'https://user:pass@github.com/file'):
            with self.assertRaises(ValueError):
                ci.check_url(url, hosts)
        ci.check_url('https://release-assets.githubusercontent.com/path?token=redacted', hosts)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.entry = {'url': 'https://github.com/fixed', 'filename': 'file',
                      'sha256': hashlib.sha256(b'fixed').hexdigest(), 'max_bytes': 100}

    class Response(io.BytesIO):
        status = 200
        def geturl(self):
            return 'https://release-assets.githubusercontent.com/fixed?secret=token'

    def opener(self, data):
        response = self.Response(data)
        class Opener:
            def open(self, url, timeout):
                return response
        return patch.object(ci.urllib.request, 'build_opener', return_value=Opener())

    def test_stream_hash_and_redirect_token_redaction(self):
        with self.opener(b'fixed'):
            record = ci.download(self.entry, self.root / 'file', ci.load_lock()['redirect_hosts'])
        self.assertEqual((self.root / 'file').read_bytes(), b'fixed')
        self.assertNotIn('secret', record['final_url'])
        self.assertFalse((self.root / 'file.partial').exists())

    def test_bad_hash_or_size_no_final_file(self):
        for index, entry in enumerate((dict(self.entry, sha256='0' * 64), dict(self.entry, max_bytes=1))):
            with self.opener(b'fixed'):
                with self.assertRaises(ValueError):
                    ci.download(entry, self.root / f'file{index}', ci.load_lock()['redirect_hosts'])
            self.assertFalse((self.root / f'file{index}').exists())
            self.assertFalse((self.root / f'file{index}.partial').exists())

    def test_preexisting_partial_is_not_deleted(self):
        partial = self.root / 'file.partial'
        partial.write_bytes(b'other owner')
        with self.opener(b'fixed'):
            with self.assertRaises(FileExistsError):
                ci.download(self.entry, self.root / 'file', ci.load_lock()['redirect_hosts'])
        self.assertEqual(partial.read_bytes(), b'other owner')

    def test_publish_never_replaces_existing_output(self):
        source, final = self.root / 'source', self.root / 'final'
        source.mkdir(); final.mkdir()
        (final / 'other').write_text('other owner')
        with self.assertRaises(OSError):
            ci.publish_absent(source, final)
        self.assertTrue(source.exists())
        self.assertEqual((final / 'other').read_text(), 'other owner')


if __name__ == '__main__':
    unittest.main()
