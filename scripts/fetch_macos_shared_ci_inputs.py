#!/usr/bin/env python3
"""Acquire authenticated dependency inputs into an independent, immutable tree.

This is not the shared mpv builder or a release entry. It never calls the normal
ensure hook. Explicit sign-contexts derives complete contexts only from the
authenticated archives; fetch and raw verification never sign or build anything.
"""
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
LOCK = HERE / 'macos-shared-ci-inputs.lock.json'
LOCK_SHA256 = '8c3ec367b8d89e74d0b2ce6beefb74e240a5defa85846b8bc899b54a69766ab9'
FRAMEWORKS = ('Ass', 'Freetype', 'Fribidi', 'Harfbuzz', 'Png16')
ARCHES = ('arm64', 'x86_64')
MANIFEST = 'acquisition-manifest.json'
SIGNED_MANIFEST = 'signed-context-manifest.json'
HOST = HERE / 'ci_macos_framework_host'


def bytes_sha(data):
    return hashlib.sha256(data).hexdigest()


def macho_payload(data):
    """Fingerprint executable sections, load commands and used linkedit data.

    Only LC_CODE_SIGNATURE and __LINKEDIT's final virtual/file sizes are omitted.
    Header ncmds/sizeofcmds and unused alignment padding may change when signing.
    CPU/file flags, all other commands, section bytes/relocations, symbol tables,
    dyld streams and UUID/minOS/install IDs remain covered. This is a semantic
    signing-invariant fingerprint, not a claim of unchanged whole-file bytes.
    """
    def region(offset, size):
        if offset < 0 or size < 0 or offset + size > len(data):
            fail('Mach-O payload range is out of bounds')
        return bytes_sha(data[offset:offset + size])
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        fail('only little-endian Mach-O64 slices are supported')
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data)
    if cpu not in (0x100000C, 0x1000007) or filetype != 6 or ncmds > 4096 or 32 + sizeofcmds > len(data):
        fail('unsupported Mach-O CPU/type/command bounds')
    commands, sections, linkedit = [], [], []
    minos, uuid, install_id, dependencies = None, None, None, []
    offset = 32
    def used(label, start, size):
        if size:
            linkedit.append({'kind': label, 'offset': start, 'size': size, 'sha256': region(start, size)})
    for _ in range(ncmds):
        if offset + 8 > 32 + sizeofcmds:
            fail('truncated Mach-O command')
        cmd, size = struct.unpack_from('<II', data, offset)
        if size < 8 or size % 4 or offset + size > 32 + sizeofcmds:
            fail('invalid Mach-O command size')
        raw = bytearray(data[offset:offset + size])
        if cmd == 0x1D:
            if size != 16:
                fail('invalid code signature command')
            _, _, start, length = struct.unpack('<4I', raw)
            region(start, length)
        else:
            if cmd in (0x24, 0x32):
                if minos is not None or (cmd == 0x24 and size != 16) or (cmd == 0x32 and size < 24):
                    fail('ambiguous/invalid macOS deployment target')
                if cmd == 0x32 and struct.unpack_from('<I', raw, 8)[0] != 1:
                    fail('framework slice is not macOS')
                value = struct.unpack_from('<I', raw, 8 if cmd == 0x24 else 12)[0]
                minos = [value >> 16, (value >> 8) & 255, value & 255]
            elif cmd == 0x1B:
                if size != 24 or uuid is not None:
                    fail('ambiguous/invalid Mach-O UUID')
                uuid = bytes(raw[8:24]).hex()
            elif cmd in (0xD, 0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023):
                if size < 24:
                    fail('invalid dylib command')
                start = struct.unpack_from('<I', raw, 8)[0]
                if start < 24 or start >= size or 0 not in raw[start:]:
                    fail('invalid dylib installation string')
                name = bytes(raw[start:]).split(b'\0', 1)[0].decode('utf-8')
                if cmd == 0xD:
                    if install_id is not None:
                        fail('ambiguous dylib install ID')
                    install_id = name
                else:
                    dependencies.append(name)
            if cmd == 0x19:
                if size < 72:
                    fail('truncated segment command')
                segment = bytes(raw[8:24]).rstrip(b'\0').decode('ascii')
                nsects = struct.unpack_from('<I', raw, 64)[0]
                if size != 72 + nsects * 80:
                    fail('invalid segment section table')
                if segment == '__LINKEDIT':
                    raw[32:40] = b'\0' * 8  # vmsize
                    raw[48:56] = b'\0' * 8  # filesize
                for n in range(nsects):
                    start = 72 + n * 80
                    section = struct.unpack_from('<16s16sQQ8I', raw, start)
                    sname, ssegment, addr, length, fileoff, align, reloff, nreloc, sflags, r1, r2, r3 = section
                    zerofill = (sflags & 0xFF) in (1, 0xC, 0x12)
                    sections.append({'name': sname.rstrip(b'\0').decode('ascii'),
                        'segment': ssegment.rstrip(b'\0').decode('ascii'), 'size': length,
                        'flags': sflags, 'sha256': None if zerofill else region(fileoff, length),
                        'relocations': region(reloff, nreloc * 8) if nreloc else None})
            elif cmd == 2:  # LC_SYMTAB
                if size != 24:
                    fail('invalid symtab command')
                _, _, symoff, nsyms, stroff, strsize = struct.unpack('<6I', raw)
                used('symbols', symoff, nsyms * 16)
                used('strings', stroff, strsize)
            elif cmd == 0xB:  # LC_DYSYMTAB, table element sizes for Mach-O64
                if size != 80:
                    fail('invalid dysymtab command')
                fields = struct.unpack('<20I', raw)
                for label, index, width in [('toc', 8, 8), ('modules', 10, 56),
                        ('references', 12, 4), ('indirect', 14, 4), ('extrel', 16, 8), ('locrel', 18, 8)]:
                    used(label, fields[index], fields[index + 1] * width)
            elif cmd in (0x22, 0x80000022):
                if size != 48:
                    fail('invalid dyld info command')
                fields = struct.unpack('<12I', raw)
                for n, label in enumerate(('rebase', 'bind', 'weak_bind', 'lazy_bind', 'export')):
                    used(label, fields[2 + n * 2], fields[3 + n * 2])
            elif cmd in (0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034):
                if size != 16:
                    fail('invalid linkedit data command')
                _, _, start, length = struct.unpack('<4I', raw)
                used(hex(cmd), start, length)
            commands.append(raw.hex())
        offset += size
    if offset != 32 + sizeofcmds:
        fail('Mach-O command count/size mismatch')
    result = {'cpu': cpu, 'subtype': subtype, 'filetype': filetype, 'flags': flags,
              'reserved': reserved, 'minimum_os': minos, 'uuid': uuid,
              'install_id': install_id, 'dependencies': dependencies,
              'commands': commands, 'sections': sections, 'linkedit': linkedit}
    result['payload_sha256'] = canonical(result)
    return result


def fail(message):
    raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def load_lock():
    if sha(LOCK) != LOCK_SHA256:
        fail('fixed download lock differs from reviewed script identity')
    lock = json.loads(LOCK.read_text())
    if lock['schema_version'] != 1 or tuple(lock['architectures']) != ARCHES:
        fail('unsupported download lock')
    if {p.name: sha(p) for p in HOST.iterdir() if p.is_file() and not p.is_symlink()} != lock['host_files']:
        fail('host template files differ from fixed recipe')
    if any(not p.is_file() or p.is_symlink() for p in HOST.iterdir()):
        fail('unexpected host template entry')
    return lock


def checked_path(value, *, exists=True, directory=None):
    p = Path(value).expanduser().absolute()
    if '..' in p.parts or any(c in str(p) for c in ('\n', '\r', ':', '"', "'", '\\')):
        fail(f'noncanonical/unsupported path: {p}')
    for parent in (p, *p.parents):
        if parent.is_symlink():
            fail(f'symlink path component: {parent}')
    p = p.resolve(strict=exists)
    if exists and ((directory is True and not p.is_dir()) or
                   (directory is False and not p.is_file())):
        fail(f'wrong input path type: {p}')
    return p


def overlap(a, b):
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def output_paths(output, logs, inputs=()):
    output, logs = checked_path(output, exists=False), checked_path(logs, exists=False)
    protected = [HERE.parent, *inputs]
    for p in (output, logs):
        if not p.parent.is_dir() or os.path.lexists(p):
            fail(f'output must be absent with an existing parent: {p}')
        if any(overlap(p, q) for q in protected) or any(c.endswith('.app') for c in p.parts):
            fail(f'output intersects repository/input/application: {p}')
    if overlap(output, logs):
        fail('output and logs must be independent')
    return output, logs


def tree(root, *, exclude=()):
    """Capture safe relative links, directories/modes and ordinary file bytes."""
    root = checked_path(root, directory=True)
    records = {}
    def visit(directory):
        for p in sorted(directory.iterdir()):
            key = p.relative_to(root).as_posix()
            if key in exclude:
                continue
            mode = p.lstat().st_mode
            if stat.S_ISLNK(mode):
                target = os.readlink(p)
                if Path(target).is_absolute() or '\\' in target:
                    fail(f'absolute/unsupported framework link: {p}')
                try:
                    resolved = p.resolve(strict=True)
                except (RuntimeError, OSError):
                    fail(f'dangling/cyclic framework link: {p}')
                if not resolved.is_relative_to(root):
                    fail(f'framework link escapes source: {p}')
                records[key] = {'type': 'symlink', 'target': target}
            elif stat.S_ISDIR(mode):
                records[key] = {'type': 'directory', 'mode': stat.S_IMODE(mode)}
                visit(p)
            elif stat.S_ISREG(mode):
                records[key] = {'type': 'file', 'mode': stat.S_IMODE(mode), 'sha256': sha(p)}
            else:
                fail(f'special file in input: {p}')
    visit(root)
    return records


def member_path(name):
    p = PurePosixPath(name.rstrip('/'))
    if (not name or '\\' in name or '\x00' in name or ':' in name or
            p.is_absolute() or '..' in p.parts or str(p) != name.rstrip('/') or
            any(c in name for c in ('\n', '\r'))):
        fail(f'unsafe/noncanonical archive member: {name}')
    return p


def check_url(url, hosts):
    parts = urllib.parse.urlsplit(url)
    if (parts.scheme != 'https' or parts.hostname not in hosts or parts.username or
            parts.password or parts.fragment or parts.port not in (None, 443)):
        fail(f'non-allowlisted HTTPS source/redirect: {url}')


class LockedRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, hosts):
        self.hosts = hosts

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        check_url(newurl, self.hosts)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def download(entry, destination, hosts):
    check_url(entry['url'], hosts)
    if os.path.lexists(destination):
        fail('download destination already exists')
    partial = destination.with_name(destination.name + '.partial')
    opener = urllib.request.build_opener(LockedRedirect(hosts))
    owned = False
    try:
        with opener.open(entry['url'], timeout=60) as response, partial.open('xb') as stream:
            owned = True
            check_url(response.geturl(), hosts)
            if response.status != 200:
                fail('download did not return HTTP 200')
            count = 0
            while block := response.read(1024 * 1024):
                count += len(block)
                if count > entry['max_bytes']:
                    fail('download exceeds fixed size bound')
                stream.write(block)
            # GitHub's redirect query can contain a short-lived signed token;
            # retain public host/path provenance without persisting credentials.
            final_url = urllib.parse.urlunsplit(urllib.parse.urlsplit(response.geturl())._replace(query=''))
        if sha(partial) != entry['sha256']:
            fail(f'download checksum differs: {entry["filename"]}')
        os.link(partial, destination)  # exclusive; never overwrite a racing file
        return {'url': entry['url'], 'final_url': final_url, 'bytes': count,
                'sha256': entry['sha256'], 'filename': entry['filename']}
    finally:
        if owned and partial.exists():
            partial.unlink()


def extract_header(archive, destination, header):
    with tarfile.open(archive, 'r:xz') as stream:
        members, seen = [], set()
        for m in stream:
            member_path(m.name)
            if m.name in seen or not (m.isdir() or m.isfile()):
                fail('duplicate/link/special source archive member')
            seen.add(m.name)
            if m.name == header['member']:
                members.append(m)
        if len(members) != 1 or not members[0].isfile() or members[0].size > header['max_bytes']:
            fail('missing/ambiguous/oversized fixed uchardet header')
        data = stream.extractfile(members[0]).read(header['max_bytes'] + 1)
    if hashlib.sha256(data).hexdigest() != header['sha256']:
        fail('uchardet header differs from fixed source bytes')
    destination.write_bytes(data)
    destination.chmod(0o644)
    return {'archive_member': header['member'], 'sha256': header['sha256'], 'bytes': len(data)}


def zip_entries(stream, limit):
    result, total = {}, 0
    for entry in stream.infolist():
        p = member_path(entry.filename)
        key = str(p)
        mode = entry.external_attr >> 16
        kind = stat.S_IFMT(mode)
        if key in result or entry.flag_bits & 1 or kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
            fail('duplicate/encrypted/special ZIP member')
        if entry.is_dir() != (kind == stat.S_IFDIR) and kind != 0:
            fail('ZIP entry type/name disagreement')
        total += entry.file_size
        if total > limit:
            fail('ZIP expansion exceeds fixed bound')
        result[key] = (entry, mode)
    return result


def extract_framework(archive, destination, entry, name):
    with zipfile.ZipFile(archive) as stream:
        entries = zip_entries(stream, entry['max_expanded_bytes'])
        infos = [p for p in entries if p == entry['xcframework'] + '/Info.plist' or
                 p.endswith('/' + entry['xcframework'] + '/Info.plist')]
        if len(infos) != 1:
            fail('XCFramework requires one metadata root')
        metadata = plistlib.loads(stream.read(entries[infos[0]][0]))
        matches = [v for v in metadata.get('AvailableLibraries', []) if
                   v.get('SupportedPlatform') == 'macos' and not v.get('SupportedPlatformVariant')]
        if (len(matches) != 1 or matches[0].get('LibraryIdentifier') != entry['library_identifier'] or
                matches[0].get('LibraryPath') != entry['framework'] or
                set(matches[0].get('SupportedArchitectures', [])) != set(ARCHES)):
            fail('XCFramework macOS universal metadata differs')
        prefix = infos[0][:-len('Info.plist')] + entry['library_identifier'] + '/' + entry['framework']
        selected = {p[len(prefix) + 1:]: v for p, v in entries.items() if p.startswith(prefix + '/')}
        if not selected or entry['binary'] not in selected:
            fail('framework is missing its fixed binary')
        # Every parent is created as a real directory. Links are installed last,
        # after their payload paths, and can never be extraction write parents.
        links = []
        for relative, (info, mode) in sorted(selected.items()):
            target = destination / relative
            if stat.S_ISLNK(mode):
                link = stream.read(info).decode('utf-8')
                if not link or PurePosixPath(link).is_absolute() or '\\' in link or '\x00' in link:
                    fail('unsafe framework archive link')
                links.append((target, link))
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if info.is_dir():
                target.mkdir(exist_ok=True)
            else:
                with stream.open(info) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if mode & 0o111 else 0o644)
        for target, link in links:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(link)
    captured = tree(destination)
    binary = destination / entry['binary']
    if binary.is_symlink() or not binary.is_file():
        fail('fixed framework binary must be a regular file')
    return {'artifact': name, 'metadata_member': infos[0], 'framework': entry['framework'],
            'binary': entry['binary'], 'binary_sha256': sha(binary),
            'tree': captured, 'tree_sha256': canonical(captured)}


def publish_absent(stage, output):
    if sys.platform == 'darwin':
        libc = ctypes.CDLL(None, use_errno=True)
        function = libc.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        if function(os.fsencode(stage), os.fsencode(output), 4):
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(output))
    else:
        if os.path.lexists(output):
            raise FileExistsError(errno.EEXIST, 'output exists', output)
        stage.rename(output)


def fetch(output, logs):
    lock = load_lock()
    output, logs = output_paths(output, logs)
    logs.mkdir()
    result = {'schema_version': 1, 'status': 'failed', 'mode': 'fixed-dependency-acquisition'}
    try:
        with tempfile.TemporaryDirectory(prefix='.shared-ci-fetch-', dir=output.parent) as tmp:
            stage = Path(tmp) / 'payload'
            (stage / 'archives').mkdir(parents=True)
            (stage / 'frameworks').mkdir()
            (stage / 'include').mkdir()
            downloads = {}
            for name, entry in lock['artifacts'].items():
                downloads[name] = download(entry, stage / 'archives' / entry['filename'], lock['redirect_hosts'])
                write_json(logs / (name + '-download.json'), downloads[name])
            header = extract_header(stage / 'archives' / lock['artifacts']['uchardet']['filename'],
                                    stage / 'include/uchardet.h', lock['header'])
            frameworks = {name: extract_framework(stage / 'archives' / lock['artifacts'][name]['filename'],
                          stage / 'frameworks' / (name + '.framework'), lock['artifacts'][name], name)
                          for name in FRAMEWORKS}
            manifest = {'schema_version': 1, 'kind': 'authenticated-raw-dependencies',
                        'output': str(output), 'lock_sha256': LOCK_SHA256,
                        'acquirer_sha256': sha(__file__), 'downloads': downloads,
                        'header': header, 'frameworks': frameworks, 'files': tree(stage)}
            write_json(stage / MANIFEST, manifest)
            # Validate actual extraction/source binding before exclusive publication.
            verify(stage, expected_output=output)
            publish_absent(stage, output)
            result.update(status='published-raw-dependencies', output=str(output),
                          manifest_sha256=sha(output / MANIFEST))
            return result
    except BaseException as error:
        result['error'] = str(error)
        raise
    finally:
        write_json(logs / 'result.json', result)


def verify(directory, *, expected_output=None):
    lock = load_lock()
    directory = checked_path(directory, directory=True)
    if (directory / MANIFEST).is_symlink() or not (directory / MANIFEST).is_file():
        fail('raw dependency manifest must be a regular file')
    manifest = json.loads((directory / MANIFEST).read_text())
    if (manifest.get('schema_version') != 1 or manifest.get('kind') != 'authenticated-raw-dependencies' or
            manifest.get('output') != str(expected_output if expected_output else directory) or
            manifest.get('lock_sha256') != LOCK_SHA256 or manifest.get('acquirer_sha256') != sha(__file__) or
            tree(directory, exclude=(MANIFEST,)) != manifest['files'] or
            set(manifest['downloads']) != set(lock['artifacts']) or set(manifest['frameworks']) != set(FRAMEWORKS)):
        fail('raw dependency manifest/source/files identity differs')
    for name, entry in lock['artifacts'].items():
        path = directory / 'archives' / entry['filename']
        record = manifest['downloads'][name]
        if (path.is_symlink() or sha(path) != entry['sha256'] or record['sha256'] != entry['sha256'] or
                record['url'] != entry['url'] or record['filename'] != entry['filename'] or
                record['bytes'] != path.stat().st_size):
            fail('archive/source binding differs')
        check_url(record['final_url'], lock['redirect_hosts'])
    # Re-derive selected bytes/tree from each authenticated archive. A modified
    # extraction cannot pass simply by resealing a self-consistent JSON manifest.
    with tempfile.TemporaryDirectory(prefix='shared-ci-verify-') as tmp:
        tmp = Path(tmp).resolve()
        header = extract_header(directory / 'archives' / lock['artifacts']['uchardet']['filename'],
                                tmp / 'uchardet.h', lock['header'])
        if header != manifest['header'] or sha(directory / 'include/uchardet.h') != header['sha256']:
            fail('header is not the authenticated source member')
        for name in FRAMEWORKS:
            derived = extract_framework(directory / 'archives' / lock['artifacts'][name]['filename'],
                        tmp / (name + '.framework'), lock['artifacts'][name], name)
            original = directory / 'frameworks' / (name + '.framework')
            if derived != manifest['frameworks'][name] or tree(original) != derived['tree']:
                fail('framework is not the authenticated source tree')
    return manifest


class ToolRunner:
    def __init__(self, logs):
        self.logs, self.index = logs, 0

    def run(self, argv, *, required=True):
        argv = [str(p) for p in argv]
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(('DYLD_', 'CODE_SIGN', 'OTHER_', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS')) or key in (
                    'SDKROOT', 'ARCHS', 'ONLY_ACTIVE_ARCH', 'SYMROOT', 'OBJROOT', 'CONFIGURATION_BUILD_DIR',
                    'DEVELOPER_DIR', 'TOOLCHAINS', 'XCODE_XCCONFIG_FILE', 'CPATH', 'LIBRARY_PATH'):
                env.pop(key, None)
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        process = subprocess.run(argv, env=env, text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        result = {'argv': argv, 'exit_code': process.returncode,
                  'stdout': process.stdout, 'stderr': process.stderr}
        self.index += 1
        write_json(self.logs / f'tool-{self.index:04d}.json', result)
        if required and process.returncode:
            fail(f'tool failed ({process.returncode}): {argv[0]}: {process.stderr[-2000:]}')
        return result


def source_classification(has_lc, display, context, isolated):
    """Reviewed narrow distinction: bad signed code is never repaired."""
    import re
    text = display['stderr'] + display['stdout']
    cdhash = re.search(r'^CDHash=([0-9a-fA-F]{40})$', text, re.M)
    if context['exit_code'] == 0:
        # Complete context verification covers code pages and resource/Info
        # bindings. An isolated thin loses that bundle metadata, so its verify
        # result is recorded but cannot invalidate an actually valid context.
        if not has_lc or display['exit_code'] or not cdhash:
            fail('complete context has contradictory code signature evidence')
        return {'class': 'valid-complete-context', 'cdhash': cdhash.group(1)}
    if not has_lc:
        if (display['exit_code'] == 0 or 'not signed at all' not in text or
                isolated['exit_code'] == 0 or 'not signed at all' not in isolated['stderr']):
            fail('ambiguous unsigned source signature')
        return {'class': 'unsigned-code', 'cdhash': None}
    if display['exit_code'] or not cdhash or isolated['exit_code']:
        fail('existing source code signature is invalid; refusing re-sign')
    flags = re.search(r'flags=0x([0-9a-fA-F]+)\(([^)]+)\)', text)
    if (not flags or int(flags.group(1), 16) != 0x20002 or 'linker-signed' not in flags.group(2) or
            'Info.plist=not bound' not in text or 'Sealed Resources=none' not in text or
            'code has no resources but signature indicates they must be present' not in context['stderr']):
        fail('invalid/unknown/resource-bound framework context cannot be re-signed')
    return {'class': 'valid-linker-code-without-bundle-resources', 'cdhash': cdhash.group(1)}


def inspect_framework(root, name, tools, *, final=False):
    import re
    captured = tree(root)
    binary = root / 'Versions/A' / name
    if binary.is_symlink() or not binary.is_file():
        fail('framework binary is not the fixed regular file')
    arches = tools.run(['/usr/bin/lipo', '-archs', binary])['stdout'].split()
    if len(arches) != 2 or set(arches) != set(ARCHES):
        fail('framework binary is not exactly universal arm64+x86_64')
    records = {}
    for arch in ARCHES:
        lc = tools.run(['/usr/bin/otool', '-arch', arch, '-l', binary])['stdout']
        display = tools.run(['/usr/bin/codesign', '--display', '--arch', arch, '-vvvv', binary], required=False)
        context = tools.run(['/usr/bin/codesign', '--verify', '--strict', '--arch', arch, root], required=False)
        with tempfile.TemporaryDirectory(prefix='.source-thin-', dir=tools.logs) as tmp:
            thin = Path(tmp) / arch
            tools.run(['/usr/bin/lipo', binary, '-thin', arch, '-output', thin])
            isolated = tools.run(['/usr/bin/codesign', '--verify', '--strict', thin], required=False)
            payload = macho_payload(thin.read_bytes())
            thin_sha = sha(thin)
        signature = source_classification(bool(re.search(r'\bcmd LC_CODE_SIGNATURE\b', lc)),
                                          display, context, isolated)
        if final and signature['class'] != 'valid-complete-context':
            fail('derived framework lacks a valid complete resource signature')
        expected_cpu = 0x100000C if arch == 'arm64' else 0x1000007
        if (payload['cpu'] != expected_cpu or payload['minimum_os'] is None or
                tuple(payload['minimum_os']) > (12, 0, 0) or payload['uuid'] is None or
                payload['install_id'] != f'@rpath/{name}.framework/Versions/A/{name}'):
            fail('framework ABI/minOS/UUID/install ID differs from contract')
        for dependency in payload['dependencies']:
            if not dependency.startswith(('/usr/lib/', '/System/Library/', '@rpath/')) or '..' in PurePosixPath(dependency).parts:
                fail('framework contains unsupported/escaping runtime linkage')
        records[arch] = {'signature': signature, 'thin_sha256': thin_sha,
                         'payload': payload, 'strict_context_exit': context['exit_code'],
                         'strict_isolated_exit': isolated['exit_code']}
    classes = [records[arch]['signature']['class'] for arch in ARCHES]
    preserve = classes == ['valid-complete-context'] * 2
    if not preserve:
        if classes != ['valid-linker-code-without-bundle-resources', 'unsigned-code']:
            fail('unsupported mixed framework signing policy')
        if any('_CodeSignature' in PurePosixPath(key).parts for key in captured):
            fail('linker-only source has unexpected existing bundle resource signature')
    if tree(root) != captured:
        fail('framework source changed during inspection')
    return {'binary_sha256': sha(binary), 'tree': captured, 'tree_sha256': canonical(captured),
            'architectures': records, 'preserve_complete_context': preserve}


def resource_identity(captured, name):
    return {key: value for key, value in captured.items() if key != 'Versions/A/' + name
            and key != '_CodeSignature' and key != 'Versions/A/_CodeSignature'
            and not key.startswith('Versions/A/_CodeSignature/')}


def validate_derivation(before, after, name):
    if not after['preserve_complete_context']:
        fail('derived complete framework signature is invalid')
    if resource_identity(before['tree'], name) != resource_identity(after['tree'], name):
        fail('framework metadata/resources changed during bundle signing')
    for arch in ARCHES:
        if before['architectures'][arch]['payload'] != after['architectures'][arch]['payload']:
            fail('signing changed code payload/ABI/minOS/UUID/install ID/dependencies')
    if before['preserve_complete_context'] and before != after:
        fail('valid complete input context was re-signed/modified')


def structural_diff(before, after, path=''):
    """Exact JSON field differences for diagnostics only, never gate normalization."""
    if type(before) is type(after) and isinstance(before, dict):
        rows = []
        for key in sorted(before.keys() | after.keys()):
            field = path + '/' + str(key).replace('~', '~0').replace('/', '~1')
            if key not in before or key not in after:
                rows.append({'path': field, 'before': before.get(key), 'after': after.get(key),
                             'before_present': key in before, 'after_present': key in after})
            else:
                rows.extend(structural_diff(before[key], after[key], field))
        return rows
    if type(before) is type(after) and isinstance(before, list):
        rows = []
        for index in range(max(len(before), len(after))):
            field = path + '/' + str(index)
            if index >= len(before) or index >= len(after):
                rows.append({'path': field, 'before': before[index] if index < len(before) else None,
                             'after': after[index] if index < len(after) else None,
                             'before_present': index < len(before), 'after_present': index < len(after)})
            else:
                rows.extend(structural_diff(before[index], after[index], field))
        return rows
    return [] if before == after else [{'path': path, 'before': before, 'after': after}]


def record_derivation(logs, name, before, after):
    # Independent logs survive removal of a failed private stage. Preserve the
    # complete fingerprints, including symbol/string streams and load commands.
    write_json(logs / ('derivation-' + name + '.json'), {
        'framework': name, 'before': before, 'after': after,
        'payload_diff': {arch: structural_diff(before['architectures'][arch]['payload'],
                         after['architectures'][arch]['payload']) for arch in ARCHES},
        'resource_diff': structural_diff(resource_identity(before['tree'], name),
                                         resource_identity(after['tree'], name)),
        'tree_diff': structural_diff(before['tree'], after['tree'])})


def host_identity():
    load_lock()
    return tree(HOST)


def render_host(directory, frameworks, preserve):
    directory.mkdir()
    for name in ('main.c', 'Info.plist'):
        shutil.copy2(HOST / name, directory / name)
    project = directory / 'FrameworkSigningHost.xcodeproj'
    project.mkdir()
    content = (HOST / 'project.pbxproj.in').read_text().replace('__FRAMEWORK_SOURCE_ROOT__', str(frameworks))
    for name in FRAMEWORKS:
        content = content.replace('__' + name.upper() + '_SIGN_ATTRIBUTE__',
                                  '' if preserve[name] else 'CodeSignOnCopy,')
    if '__' in content:
        fail('host template contains unresolved placeholders')
    (project / 'project.pbxproj').write_text(content)
    return project


def toolchain(tools):
    return {name: tools.run(argv)['stdout'].strip() for name, argv in {
        'xcode': ['/usr/bin/xcodebuild', '-version'],
        'developer_directory': ['/usr/bin/xcode-select', '-p'],
        'sdk_path': ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
        'sdk_version': ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version']}.items()}


def signing_contexts(inputs, output, logs):
    if sys.platform != 'darwin':
        fail('Xcode signing host requires macOS')
    raw = verify(inputs)
    inputs = checked_path(inputs, directory=True)
    output, logs = output_paths(output, logs, (inputs,))
    logs.mkdir()
    tools = ToolRunner(logs)
    result = {'schema_version': 1, 'status': 'failed', 'mode': 'framework-context-derivation'}
    owned_inode = None
    try:
        host = host_identity()
        chain = toolchain(tools)
        before = {name: inspect_framework(inputs / 'frameworks' / (name + '.framework'), name, tools)
                  for name in FRAMEWORKS}
        write_json(logs / 'source-inspection.json', before)
        with tempfile.TemporaryDirectory(prefix='.shared-ci-sign-', dir=output.parent) as tmp:
            tmp = Path(tmp)
            sources = tmp / 'host-inputs'
            sources.mkdir()
            for name in FRAMEWORKS:
                source = inputs / 'frameworks' / (name + '.framework')
                shutil.copytree(source, sources / source.name, symlinks=True)
                if tree(sources / source.name) != before[name]['tree']:
                    fail('private signing copy differs from authenticated source')
            project = render_host(tmp / 'project', sources,
                                  {name: before[name]['preserve_complete_context'] for name in FRAMEWORKS})
            built = tmp / 'built'
            tools.run(['/usr/bin/xcodebuild', '-project', project, '-target', 'FrameworkSigningHost',
                '-configuration', 'Release', 'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO',
                'COPY_PHASE_STRIP=NO', 'DEPLOYMENT_POSTPROCESSING=NO', 'STRIP_INSTALLED_PRODUCT=NO',
                'MACOSX_DEPLOYMENT_TARGET=12.0', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual',
                'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES', 'DEVELOPMENT_TEAM=',
                'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO', 'SDKROOT=' + chain['sdk_path'],
                'SYMROOT=' + str(tmp / 'sym'), 'OBJROOT=' + str(tmp / 'obj'),
                'CONFIGURATION_BUILD_DIR=' + str(built)])
            derived = built / 'FrameworkSigningHost.app/Contents/Frameworks'
            stage = tmp / 'payload'
            (stage / 'frameworks').mkdir(parents=True)
            stage_records = {}
            for name in FRAMEWORKS:
                target = stage / 'frameworks' / (name + '.framework')
                # Check the output link graph before copy; never follow escaped links.
                tree(derived / target.name)
                shutil.copytree(derived / target.name, target, symlinks=True)
                after = inspect_framework(target, name, tools, final=True)
                record_derivation(logs, name, before[name], after)
                stage_records[name] = after
            # Gather all five before validation so the first payload failure
            # cannot discard the other framework/ABI comparisons.
            for name in FRAMEWORKS:
                validate_derivation(before[name], stage_records[name], name)
                if tree(sources / (name + '.framework')) != before[name]['tree']:
                    fail('Xcode modified its private source copy')
            write_json(stage / 'stage-inspection.json', stage_records)
            if verify(inputs) != raw or host_identity() != host or toolchain(tools) != chain:
                fail('raw inputs, host template or toolchain changed during signing')
            publish_absent(stage, output)
            owned_inode = output.lstat().st_ino
            # Real final-path verification precedes the atomic seal.
            final = {name: inspect_framework(output / 'frameworks' / (name + '.framework'), name, tools, final=True)
                     for name in FRAMEWORKS}
            if final != stage_records or verify(inputs) != raw:
                fail('final context/source identity differs from actual stage inspection')
            write_json(output / 'final-inspection.json', final)
            manifest = {'schema_version': 1, 'kind': 'derived-signed-framework-contexts',
                'output': str(output), 'raw_inputs': str(inputs), 'raw_manifest_sha256': sha(inputs / MANIFEST),
                'lock_sha256': LOCK_SHA256, 'acquirer_sha256': sha(__file__), 'host_files': host,
                'toolchain': chain, 'before': before, 'after': final, 'files': tree(output),
                'policy': 'valid-complete-preserved-or-verified-linker-code-bundle-sign-v1'}
            seal = output / '.seal-stage'
            seal.mkdir()
            write_json(seal / SIGNED_MANIFEST, manifest)
            publish_absent(seal, output / 'sealed')
            result.update(status='published-signed-contexts', output=str(output),
                          manifest_sha256=sha(output / 'sealed' / SIGNED_MANIFEST))
            return result
    except BaseException as error:
        result['error'] = str(error)
        if owned_inode is not None and output.exists() and not output.is_symlink() and output.lstat().st_ino == owned_inode:
            shutil.rmtree(output)
        raise
    finally:
        write_json(logs / 'result.json', result)


def verify_contexts(inputs, directory, tools):
    raw = verify(inputs)
    inputs, directory = checked_path(inputs, directory=True), checked_path(directory, directory=True)
    seal = directory / 'sealed'
    if seal.is_symlink() or not seal.is_dir() or {p.name for p in seal.iterdir()} != {SIGNED_MANIFEST}:
        fail('signed contexts have no complete seal')
    if (seal / SIGNED_MANIFEST).is_symlink() or not (seal / SIGNED_MANIFEST).is_file():
        fail('signed context manifest must be a regular file')
    manifest = json.loads((seal / SIGNED_MANIFEST).read_text())
    if (manifest.get('schema_version') != 1 or manifest.get('kind') != 'derived-signed-framework-contexts' or
            manifest.get('output') != str(directory) or manifest.get('raw_inputs') != str(inputs) or
            manifest.get('raw_manifest_sha256') != sha(inputs / MANIFEST) or
            manifest.get('lock_sha256') != LOCK_SHA256 or manifest.get('acquirer_sha256') != sha(__file__) or
            manifest.get('host_files') != host_identity() or
            manifest.get('policy') != 'valid-complete-preserved-or-verified-linker-code-bundle-sign-v1' or
            tree(directory, exclude=('sealed',)) != manifest['files'] or
            set(manifest['before']) != set(FRAMEWORKS) or set(manifest['after']) != set(FRAMEWORKS)):
        fail('signed context provenance/files/source identity differs')
    for name in FRAMEWORKS:
        source = inspect_framework(inputs / 'frameworks' / (name + '.framework'), name, tools)
        derived = inspect_framework(directory / 'frameworks' / (name + '.framework'), name, tools, final=True)
        if source != manifest['before'][name] or derived != manifest['after'][name]:
            fail('actual source/derived signature identity differs from sealed evidence')
        validate_derivation(source, derived, name)
    if verify(inputs) != raw:
        fail('source changed during signed context verification')
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    acquire = commands.add_parser('fetch', help='download/extract fixed raw dependencies only')
    acquire.add_argument('--output', type=Path, required=True)
    acquire.add_argument('--log-dir', type=Path, required=True)
    check = commands.add_parser('verify', help='rederive payload from fixed archived sources')
    check.add_argument('--directory', type=Path, required=True)
    signing = commands.add_parser('sign-contexts', help='build-only Xcode host; never launches UI')
    signing.add_argument('--inputs', type=Path, required=True)
    signing.add_argument('--output', type=Path, required=True)
    signing.add_argument('--log-dir', type=Path, required=True)
    signed_check = commands.add_parser('verify-contexts', help='strictly verify source and derived context binding')
    signed_check.add_argument('--inputs', type=Path, required=True)
    signed_check.add_argument('--directory', type=Path, required=True)
    signed_check.add_argument('--log-dir', type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == 'fetch':
        result = fetch(args.output, args.log_dir)
    elif args.command == 'verify':
        manifest = verify(args.directory)
        result = {'verified': manifest['output'], 'kind': manifest['kind']}
    elif args.command == 'sign-contexts':
        result = signing_contexts(args.inputs, args.output, args.log_dir)
    else:
        inputs, directory = checked_path(args.inputs, directory=True), checked_path(args.directory, directory=True)
        logs = checked_path(args.log_dir, exists=False)
        if (os.path.lexists(logs) or not logs.parent.is_dir() or any(overlap(logs, p) for p in (inputs, directory, HERE.parent))):
            fail('verification logs must be a fresh independent directory')
        logs.mkdir()
        manifest = verify_contexts(inputs, directory, ToolRunner(logs))
        result = {'verified': manifest['output'], 'kind': manifest['kind']}
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(2)
