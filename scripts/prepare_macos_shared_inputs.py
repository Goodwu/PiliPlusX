#!/usr/bin/env python3
"""Prepare immutable, explicit inputs for the opt-in shared macOS mpv builder.

This does not build mpv, download anything, edit an application or enable a
production backend. The dependency lock is a verified snapshot for one output
location, not a portable approval of arbitrary caller-supplied libraries.
"""
import argparse
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile
import subprocess
import re
import stat

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ARCHES = ('arm64', 'x86_64')
RUNTIME_LIBS = {'libplacebo.dylib', 'libshaderc_shared.1.dylib',
                'libvulkan.1.dylib', 'liblcms2.2.dylib'}
PINNED = {
    'goodwu_archive': '2965439e9d239a441263288140b2d8b09ee877478084916f63575a1775de97a4',
    'mpv_archive': 'ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209',
    'ffmpeg_archive': 'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635',
    'libass_archive': '5ba42655d7e8c5e87bba3ffc8a2b1bc19c29904240126bb0d4b924f39429219f',
}
RECIPE_FILES = ('build_macos.py', 'prepare.py', 'verify_source.py',
                'manifest.json', 'mpv-0.41-shared-core.patch')


def fail(message):
    raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def checked_path(value, directory=False):
    p = Path(value).expanduser().absolute()
    for q in (p, *p.parents):
        if q.is_symlink():
            fail(f'symlink input/output path is forbidden: {q}')
    if (directory and not p.is_dir()) or (not directory and not p.is_file()):
        fail(f'missing or incorrect input type: {p}')
    if any(c in str(p) for c in ('\n', '\r', ':', "'", '"')):
        fail(f'unsupported input path characters: {p}')
    return p.resolve()


def tree_files(directory, framework_links=False):
    directory = directory.resolve(strict=True)
    result = {}
    def walk(folder):
        for p in sorted(folder.iterdir()):
            relative = p.relative_to(directory).as_posix()
            mode = p.lstat().st_mode
            if stat.S_ISLNK(mode):
                parts = p.relative_to(directory).parts
                allowed = directory if framework_links else (
                    directory / parts[0] / parts[1] if len(parts) > 2 and
                    parts[0] == 'framework-context' and parts[1].endswith('.framework') else None)
                target = os.readlink(p)
                if allowed is None or PurePosixPath(target).is_absolute():
                    fail(f'unsupported input symlink: {p}')
                try:
                    resolved = p.resolve(strict=True)
                except (OSError, RuntimeError):
                    fail(f'broken or cyclic framework link: {p}')
                if not resolved.is_relative_to(allowed):
                    fail(f'framework symlink escapes its context: {p}')
                result[relative] = {'symlink': target}
            elif stat.S_ISREG(mode):
                result[relative] = sha(p)
            elif stat.S_ISDIR(mode):
                if framework_links or p.relative_to(directory).parts[0] == 'framework-context':
                    result[relative] = {'directory': True}
                walk(p)
            else:
                fail(f'unsupported input entry: {p}')
    walk(directory)
    if not result:
        fail(f'empty input directory: {directory}')
    return result


def files(directory):
    return tree_files(directory)


def check_output(output, protected):
    output = Path(output).expanduser().absolute()
    for p in (output, *output.parents):
        if p.is_symlink():
            fail(f'symlink output path: {p}')
    if output.exists():
        fail(f'output already exists: {output}')
    if not output.parent.is_dir():
        fail('output parent must already exist')
    output = output.resolve()
    if any(part.endswith('.app') for part in output.parts):
        fail('output may not be inside an application')
    for p in protected:
        if output == p or output.is_relative_to(p) or p.is_relative_to(output):
            fail(f'output overlaps repository or input: {output} / {p}')
    return output


def extract_selected(archive, destination, select):
    """Check every tar member before copying only regular selected files."""
    with tarfile.open(archive) as stream:
        seen = set()
        for member in stream.getmembers():
            name = PurePosixPath(member.name)
            if (name.is_absolute() or '..' in name.parts or '\\' in member.name
                    or str(name) in seen or not (member.isfile() or member.isdir())):
                fail(f'unsafe/duplicate archive member: {member.name}')
            seen.add(str(name))
            relative = select(name) if member.isfile() else None
            if relative is None:
                continue
            target = destination / relative
            if not target.resolve().is_relative_to(destination.resolve()) or target.exists():
                fail(f'unsafe or duplicate extraction output: {target}')
            target.parent.mkdir(parents=True, exist_ok=True)
            with stream.extractfile(member) as source, target.open('xb') as dest:
                shutil.copyfileobj(source, dest)


def runtime_identity(directory, runtime):
    manifest = json.loads((directory / 'manifest.json').read_text())
    if (manifest['schema'] != 1 or manifest['versions'] != runtime.VERSIONS
            or manifest['sources']['libplacebo']['commit'] != runtime.LIBPLACEBO_COMMIT
            or manifest['sources']['source_archives_sha256'] !=
            {name: record[1] for name, record in runtime.SOURCE_ARCHIVES.items()}
            or set(manifest['libraries']) != RUNTIME_LIBS):
        fail('runtime source/version/library manifest mismatch')
    for name in RUNTIME_LIBS:
        library = checked_path(directory / name)
        if sha(library) != manifest['libraries'][name]['sha256']:
            fail(f'runtime library checksum mismatch: {name}')
    return manifest


def relocate(value, old, new):
    """Map only absolute stage path strings/keys; file/hash/version data is intact."""
    if isinstance(value, str):
        if value == str(old) or value.startswith(str(old) + '/'):
            return str(new) + value[len(str(old)):]
        return value
    if isinstance(value, list):
        return [relocate(v, old, new) for v in value]
    if isinstance(value, dict):
        return {relocate(k, old, new): relocate(v, old, new) for k, v in value.items()}
    return value


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def publish_absent(stage, destination):
    # macOS renamex_np RENAME_EXCL prevents replacing even an empty directory
    # created by another process after our preflight.
    if sys.platform == 'darwin':
        libc = ctypes.CDLL(None, use_errno=True)
        function = libc.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        if function(os.fsencode(stage), os.fsencode(destination), 4):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(destination))
    else:
        # Non-macOS is used only for pure orchestration unit tests.
        if os.path.lexists(destination):
            raise FileExistsError(errno.EEXIST, 'destination exists', destination)
        stage.rename(destination)


def signature_tool(command):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('DYLD_'):
            env.pop(key, None)
    result = subprocess.run([str(p) for p in command], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return result.returncode, result.stdout


def signature_state(path, arch, builder, context=None):
    has_lc = bool(re.search(r'\bcmd LC_CODE_SIGNATURE\b',
                           builder.output(['otool', '-arch', arch, '-l', path])))
    display_code, display = signature_tool(['codesign', '--display', '--arch', arch, '-vvvv', path])
    verify_code, verify_text = signature_tool(['codesign', '--verify', '--strict', '--arch', arch,
                                              context if context is not None else path])
    if has_lc:
        match = re.search(r'^CDHash=([0-9a-fA-F]{40})$', display, re.M)
        if display_code or verify_code or not match:
            fail(f'existing {arch} signature is invalid; refusing repair: {path}: {verify_text}')
        return {'signed': True, 'lc_code_signature': True, 'cdhash': match.group(1),
                'strict_verify_exit': 0}
    if display_code == 0 or 'not signed at all' not in display or verify_code == 0:
        fail(f'ambiguous unsigned {arch} signature evidence: {path}')
    return {'signed': False, 'lc_code_signature': False, 'cdhash': None,
            'strict_verify_exit': verify_code}


def normalize_flat_signature(path, builder):
    original_sha = sha(path)
    original_identity = {arch: builder.library_identity(path, arch) for arch in ARCHES}
    before = {arch: signature_state(path, arch, builder) for arch in ARCHES}
    record = {'source_sha256': original_sha, 'before': before, 'actions': [],
              'signed_slice_preservation': {}, 'slice_sha256': {}}
    if all(before[arch]['signed'] for arch in ARCHES):
        record.update(derived_sha256=original_sha, after=before)
        return record
    with tempfile.TemporaryDirectory(prefix='.unsigned-slices-', dir=path.parent.parent) as temporary:
        temporary = Path(temporary)
        slices = []
        preserved = {}
        for arch in ARCHES:
            thin = temporary / arch
            builder.output(['lipo', path, '-thin', arch, '-output', thin])
            state = signature_state(thin, arch, builder)
            if state != before[arch]:
                fail(f'extracted {arch} signature identity changed')
            record['slice_sha256'][arch] = {'source': sha(thin)}
            if state['signed']:
                preserved[arch] = {'sha256': sha(thin), 'cdhash': state['cdhash']}
            else:
                code, message = signature_tool(['codesign', '--sign', '-', '--identifier', path.name, thin])
                if code:
                    fail(f'unsigned {arch} signing failed: {message}')
                if not signature_state(thin, arch, builder)['signed']:
                    fail(f'unsigned {arch} signing did not produce a valid signature')
                record['actions'].append({'architecture': arch, 'action': 'adhoc-sign-unsigned-thin',
                                          'sign_exit': 0})
            record['slice_sha256'][arch]['derived'] = sha(thin)
            slices.append(thin)
        derived = temporary / 'universal.dylib'
        builder.output(['lipo', '-create', *slices, '-output', derived])
        after = {arch: signature_state(derived, arch, builder) for arch in ARCHES}
        for arch, expected in preserved.items():
            probe = temporary / (arch + '-preserved')
            builder.output(['lipo', derived, '-thin', arch, '-output', probe])
            if sha(probe) != expected['sha256'] or after[arch]['cdhash'] != expected['cdhash']:
                fail(f'valid signed {arch} slice was modified during unsigned repair')
        for arch in ARCHES:
            identity = builder.library_identity(derived, arch)
            for key in ('architectures', 'minos', 'install_dependencies'):
                actual, original = identity[key], original_identity[arch][key]
                if (set(actual) != set(original) if key == 'architectures' else actual != original):
                    fail(f'unsigned derivation changed runtime ABI/encoding identity: {key}')
        if sha(path) != original_sha:
            fail('source staged library changed during signature derivation')
        record.update(derived_sha256=sha(derived), after=after,
                      signed_slice_preservation=preserved)
        shutil.copy2(derived, path)
    return record


def signature_payload(stage, config, provenance, builder):
    # This initial actual inspection selects the real closure, not a lock.
    raw = builder.inspect_dependencies(config, ARCHES)
    libraries = raw['architectures']['arm64']['libraries']
    if set(libraries) != set(raw['architectures']['x86_64']['libraries']):
        fail('signature preparation requires the same universal closure for both ABIs')
    records, contexts = {}, {}
    for name, identity in sorted(libraries.items()):
        path = checked_path(name)
        relative = path.relative_to(stage / 'lib').as_posix()
        if sha(path) != identity['sha256']:
            fail('signature source differs from initial inspection')
        if '.framework/' not in relative:
            records[relative] = normalize_flat_signature(path, builder)
            continue
        parts = PurePosixPath(relative).parts
        if len(parts) != 4 or parts[1:3] != ('Versions', 'A'):
            fail('unsupported framework verification context layout')
        candidates = [Path(source) for source, digest in provenance['external_closure_files'].items()
                      if digest == sha(path) and Path(source).name == path.name]
        if len(candidates) != 1:
            fail('framework requires one explicit complete source context')
        source = checked_path(candidates[0])
        root = checked_path(source.parents[2], True)
        before_tree = tree_files(root, framework_links=True)
        before = {arch: signature_state(source, arch, builder, root) for arch in ARCHES}
        if not all(v['signed'] for v in before.values()):
            fail('unsigned framework verification context is forbidden')
        context = stage / 'framework-context' / parts[0]
        context.parent.mkdir(exist_ok=True)
        shutil.copytree(root, context, symlinks=True)
        binary = context / 'Versions/A' / path.name
        if (tree_files(context, framework_links=True) != before_tree or
                tree_files(root, framework_links=True) != before_tree or sha(binary) != sha(path)):
            fail('framework context changed while copying')
        after = {arch: signature_state(binary, arch, builder, context) for arch in ARCHES}
        if after != before:
            fail('framework signature changed while copying verification context')
        contexts[relative] = {'context': context.relative_to(stage).as_posix(),
                             'binary': binary.relative_to(stage).as_posix(),
                             'source_context': str(root), 'tree': before_tree}
        records[relative] = {'source_sha256': sha(path), 'derived_sha256': sha(path),
                             'before': before, 'after': after, 'actions': []}
    provenance['signature_policy'] = 'strict-existing-or-sign-only-unsigned-thin-v1'
    provenance['library_signatures'] = records
    provenance['framework_contexts'] = contexts


def verify_signatures(directory, lock, provenance, builder):
    if provenance.get('signature_policy') != 'strict-existing-or-sign-only-unsigned-thin-v1':
        fail('sealed inputs lack the standalone runtime signature policy; prepare fresh inputs')
    records = provenance['library_signatures']
    contexts = provenance['framework_contexts']
    expected_names = set()
    for source, identity in lock['architectures']['arm64']['libraries'].items():
        path = checked_path(source)
        if not path.is_relative_to(directory / 'lib'):
            fail('runtime signature path escapes prepared lib directory')
        relative = path.relative_to(directory / 'lib').as_posix()
        expected_names.add(relative)
        record = records[relative]
        if sha(path) != identity['sha256'] or sha(path) != record['derived_sha256']:
            fail('signed runtime SHA differs from lock/provenance')
        if '.framework/' in relative:
            context = contexts[relative]
            root = checked_path(directory / context['context'], True)
            binary = checked_path(directory / context['binary'])
            if (not root.is_relative_to(directory / 'framework-context') or not binary.is_relative_to(root)
                    or sha(binary) != sha(path) or tree_files(root, framework_links=True) != context['tree']):
                fail('framework context is outside inputs or differs from locked binary/tree')
            after = {arch: signature_state(binary, arch, builder, root) for arch in ARCHES}
        else:
            after = {arch: signature_state(path, arch, builder) for arch in ARCHES}
        if not all(v['signed'] for v in after.values()) or after != record['after']:
            fail('standalone runtime signature identity differs from prepared provenance')
        preserved = record.get('signed_slice_preservation', {})
        if preserved:
            with tempfile.TemporaryDirectory(prefix='.signed-slice-check-', dir=directory.parent) as temporary:
                for arch, expected in preserved.items():
                    thin = Path(temporary) / arch
                    builder.output(['lipo', path, '-thin', arch, '-output', thin])
                    if sha(thin) != expected['sha256'] or after[arch]['cdhash'] != expected['cdhash']:
                        fail('preserved signed slice differs from standalone signature provenance')
    if set(records) != expected_names or set(contexts) != {n for n in expected_names if '.framework/' in n}:
        fail('runtime signature/context provenance set differs from the locked closure')


def populate(args, stage, builder, runtime, legacy):
    provenance = {'archives': {}, 'explicit_inputs': {}, 'recipe': {},
                  'input_preparer_sha256': sha(Path(__file__)),
                  'pinned_helpers': {name: sha(HERE / name) for name in
                      ('build_macos_mpv_runtime.py', 'build_macos_mpv_x86.py')}}
    for name, expected in PINNED.items():
        path = getattr(args, name)
        if sha(path) != expected:
            fail(f'unreviewed {name}: {path}')
        provenance['archives'][name] = {'path': str(path), 'sha256': expected}
    for name in RECIPE_FILES:
        provenance['recipe'][name] = sha(checked_path(args.recipe / name))
    for name in ('libass_library', 'uchardet_header'):
        path = getattr(args, name)
        expected = getattr(args, name + '_sha256')
        if len(expected) != 64 or sha(path) != expected:
            fail(f'explicit {name} checksum mismatch')
        provenance['explicit_inputs'][name] = {'path': str(path), 'sha256': expected}
    provenance['runtime_manifest'] = runtime_identity(args.runtime_directory, runtime)
    include, libs = stage / 'include', stage / 'lib'
    include.mkdir()
    libs.mkdir()
    extract_selected(args.ffmpeg_archive, include,
                     lambda p: Path(*p.parts[1:]) if len(p.parts) > 2 and
                     p.parts[0] == 'ffmpeg-9.0.1' and p.parts[1] in legacy.FFMPEG_VERSIONS
                     and p.suffix == '.h' else None)
    (include / 'libavutil/avconfig.h').write_text(
        '#ifndef AVUTIL_AVCONFIG_H\n#define AVUTIL_AVCONFIG_H\n'
        '#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n#endif\n')
    (include / 'libavutil/ffversion.h').write_text('#define FFMPEG_VERSION "9.0.1"\n')
    extract_selected(args.libass_archive, include,
                     lambda p: Path('ass') / p.name if str(p) in
                     ('libass-0.17.1/libass/ass.h', 'libass-0.17.1/libass/ass_types.h') else None)
    shutil.copy2(args.uchardet_header, include / 'uchardet.h')
    extract_selected(args.goodwu_archive, libs,
                     lambda p: Path(p.name) if len(p.parts) == 2 and
                     p.parts[0] == 'libmpv-libs_develop_macos-universal-video-default'
                     and p.suffix == '.dylib' and p.name not in
                     ('libmpv.dylib', 'libplacebo.dylib', 'libass.dylib') else None)
    for name in RUNTIME_LIBS:
        shutil.copy2(args.runtime_directory / name, libs / name)
        if sha(libs / name) != provenance['runtime_manifest']['libraries'][name]['sha256']:
            fail(f'runtime copied bytes differ from manifest: {name}')
    shutil.copy2(args.libass_library, libs / 'libass.dylib')
    # Existing Ass.framework-to-flat conversion is an explicit derived action;
    # its original signature must be valid before installation identity changes.
    ids = [builder.install_dependencies(libs / 'libass.dylib', arch)[0] for arch in ARCHES]
    if ids != ['@rpath/libass.dylib'] * 2:
        if ids != ['@rpath/Ass.framework/Versions/A/Ass'] * 2:
            fail(f'unsupported libass install ID: {ids}')
        original_context = checked_path(args.libass_library.parents[2], True)
        original_signatures = {arch: signature_state(args.libass_library, arch, builder, original_context)
                               for arch in ARCHES}
        if not all(v['signed'] for v in original_signatures.values()):
            fail('libass framework source must already be strictly signed')
        provenance['libass_install_id_derivation'] = {'source_sha256': sha(args.libass_library),
            'source_signatures': original_signatures, 'action': 'valid-framework-to-flat-ID'}
        builder.output(['install_name_tool', '-id', '@rpath/libass.dylib', libs / 'libass.dylib'])
        builder.output(['codesign', '--force', '--sign', '-', libs / 'libass.dylib'])
    copied = {}
    pending = list(libs.iterdir())
    seen = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        for arch in ARCHES:
            entry = builder.library_identity(path, arch)
            expected_id = '@rpath/' + str(path.relative_to(libs))
            if entry['install_dependencies'][0] != expected_id:
                fail(f'noncanonical runtime install ID: {path}')
            for dep in entry['install_dependencies'][1:]:
                if dep.startswith(('/usr/lib/', '/System/Library/')):
                    continue
                if not dep.startswith('@rpath/'):
                    fail(f'unsupported or absolute dependency: {path} -> {dep}')
                relative = PurePosixPath(dep[7:])
                if '..' in relative.parts or relative.is_absolute():
                    fail(f'escaping dependency: {dep}')
                target = libs / str(relative)
                if not target.is_file():
                    candidates = [root / str(relative) for root in args.library_root
                                  if (root / str(relative)).is_file()]
                    candidates = [checked_path(p) for p in candidates]
                    if not candidates or len({sha(p) for p in candidates}) != 1:
                        fail(f'missing or ambiguous explicit dependency: {dep}')
                    source = candidates[0]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
                    copied[str(source)] = sha(source)
                pending.append(target)
    provenance['external_closure_files'] = copied
    config = {'schema_version': 1, 'architectures': {}}
    provenance['runtime_header_trees'] = {}
    for arch in ARCHES:
        source = args.runtime_work / arch / 'include'
        before = files(source)
        prefix = stage / 'prefix' / arch
        shutil.copytree(source, prefix / 'include')
        (prefix / 'lib').mkdir()
        if files(prefix / 'include') != before or files(source) != before:
            fail(f'runtime headers changed while copying: {arch}')
        provenance['runtime_header_trees'][arch] = before
        config['architectures'][arch] = {
            'prefix': str(prefix), 'vulkan_include': str(prefix / 'include'),
            'ffmpeg_include': str(include), 'libass_include': str(include),
            'uchardet_include': str(include), 'ffmpeg_lib_dir': str(libs),
            **{key: str(libs / name) for key, name in {
                'libplacebo_library': 'libplacebo.dylib', 'vulkan_library': 'libvulkan.1.dylib',
                'libass_library': 'libass.dylib', 'uchardet_library': 'libuchardet.dylib'}.items()}}
    (stage / 'archive').mkdir()
    shutil.copy2(args.mpv_archive, stage / 'archive/mpv.tar.gz')
    # Recheck external identities after all copying/inspection inputs exist.
    for name, expected in PINNED.items():
        if sha(getattr(args, name)) != expected:
            fail(f'archive changed during preparation: {name}')
    if runtime_identity(args.runtime_directory, runtime) != provenance['runtime_manifest']:
        fail('runtime changed during preparation')
    for name, identity in provenance['explicit_inputs'].items():
        if sha(getattr(args, name)) != identity['sha256']:
            fail(f'explicit input changed: {name}')
    for name, expected in provenance['recipe'].items():
        if sha(args.recipe / name) != expected:
            fail(f'recipe changed during preparation: {name}')
    for source, expected in copied.items():
        if sha(source) != expected:
            fail(f'closure input changed: {source}')
    return config, provenance


def prepare(args):
    builder = load_module(args.recipe / 'build_macos.py', 'shared_input_builder')
    runtime = load_module(HERE / 'build_macos_mpv_runtime.py', 'shared_input_runtime')
    legacy = load_module(HERE / 'build_macos_mpv_x86.py', 'shared_input_headers')
    protected = [HERE.parent, args.recipe.parent.parent, args.runtime_work,
                 args.runtime_directory, *args.library_root,
                 *(getattr(args, n).parent for n in PINNED),
                 args.libass_library.parent, args.uchardet_header.parent]
    destination = check_output(args.output, protected)
    stage = Path(tempfile.mkdtemp(prefix='.' + destination.name + '.preparing-', dir=destination.parent))
    published = False
    published_inode = None
    try:
        config, provenance = populate(args, stage, builder, runtime, legacy)
        signature_payload(stage, config, provenance, builder)
        inspected = builder.inspect_dependencies(config, ARCHES)
        write_json(stage / 'stage-inspection.json', inspected)
        final_config = relocate(config, stage, destination)
        final_lock = relocate(inspected, stage, destination)
        payload_files = files(stage)
        publish_absent(stage, destination)
        published = True
        published_inode = destination.stat().st_ino
        # No config/lock is exposed until real final paths have been independently
        # inspected. Relocation is never treated as inspection of nonexistent paths.
        actual_final = builder.inspect_dependencies(final_config, ARCHES)
        if actual_final != final_lock:
            fail('published-path dependency identity differs from stage inspection')
        if files(destination) != payload_files:
            fail('payload changed during publication')
        verify_signatures(destination, actual_final, provenance, builder)
        # Publish config, actual final-path lock and sealed manifest together.
        # Consumers use only output/sealed and must run --verify first.
        control = Path(tempfile.mkdtemp(prefix='.sealing-', dir=destination.parent))
        try:
            write_json(control / 'dependency-config.json', final_config)
            write_json(control / 'dependency-lock.json', actual_final)
            identities = files(destination)
            for name in ('dependency-config.json', 'dependency-lock.json'):
                identities['sealed/' + name] = sha(control / name)
            manifest = {'schema_version': 1, 'candidate_only': True,
                        'production_enabled': False, 'runtime_acceptance': False,
                        'output': str(destination), 'architectures': list(ARCHES),
                        'minos': '12.0', 'provenance': provenance,
                        'files': identities}
            write_json(control / 'inputs-manifest.json', manifest)
            publish_absent(control, destination / 'sealed')
        finally:
            if control.exists():
                shutil.rmtree(control)
        return manifest
    except BaseException:
        if published and destination.exists():
            if destination.is_symlink() or destination.stat().st_ino != published_inode:
                fail('output replaced externally; refusing to remove unrelated path')
            shutil.rmtree(destination)
        raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def verify(directory, recipe):
    directory = checked_path(directory, True)
    manifest_path = checked_path(directory / 'sealed/inputs-manifest.json')
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get('schema_version') != 1 or manifest.get('output') != str(directory)
            or manifest.get('architectures') != list(ARCHES)
            or manifest.get('production_enabled') is not False
            or manifest.get('candidate_only') is not True):
        fail('invalid sealed input manifest')
    actual_files = files(directory)
    actual_files.pop('sealed/inputs-manifest.json')
    if actual_files != manifest['files']:
        fail('sealed inputs file set/hash mismatch')
    for name, expected in manifest['provenance']['recipe'].items():
        if name not in RECIPE_FILES or sha(checked_path(recipe / name)) != expected:
            fail(f'recipe identity changed: {name}')
    if set(manifest['provenance']['recipe']) != set(RECIPE_FILES):
        fail('recipe file set mismatch')
    builder = load_module(recipe / 'build_macos.py', 'shared_input_verify_builder')
    config = json.loads((directory / 'sealed/dependency-config.json').read_text())
    lock = json.loads((directory / 'sealed/dependency-lock.json').read_text())
    for c in config['architectures'].values():
        for key, path in c.items():
            resolved = checked_path(path, not key.endswith('_library'))
            if str(resolved) != path or not resolved.is_relative_to(directory):
                fail('sealed configuration has a noncanonical or escaping input path')
    if builder.inspect_dependencies(config, ARCHES) != lock:
        fail('sealed input inspection differs from dependency lock')
    verify_signatures(directory, lock, manifest['provenance'], builder)
    if sha(directory / 'archive/mpv.tar.gz') != PINNED['mpv_archive']:
        fail('sealed mpv archive checksum mismatch')
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', type=Path, help='verify an existing sealed output; requires --recipe only')
    for name in (*PINNED, 'runtime_work', 'runtime_directory', 'recipe',
                 'libass_library', 'uchardet_header', 'output'):
        parser.add_argument('--' + name.replace('_', '-'), type=Path)
    parser.add_argument('--libass-library-sha256')
    parser.add_argument('--uchardet-header-sha256',
                        help='reviewed uchardet 0.0.8 header digest; no Homebrew lookup')
    parser.add_argument('--library-root', type=Path, action='append', default=[],
                        help='explicit roots for @rpath libass/FFmpeg framework dependencies')
    args = parser.parse_args(argv)
    if args.verify is not None:
        if args.recipe is None:
            parser.error('--verify requires --recipe')
        recipe = checked_path(args.recipe, True)
        manifest = verify(args.verify, recipe)
        print(json.dumps({'verified': manifest['output']}))
        return 0
    required = (*PINNED, 'runtime_work', 'runtime_directory', 'recipe', 'libass_library',
                'uchardet_header', 'output', 'libass_library_sha256', 'uchardet_header_sha256')
    for name in required:
        if getattr(args, name) is None:
            parser.error('--' + name.replace('_', '-') + ' is required for preparation')
    directories = {'runtime_work', 'runtime_directory', 'recipe'}
    for name in (*PINNED, *directories, 'libass_library', 'uchardet_header'):
        setattr(args, name, checked_path(getattr(args, name), name in directories))
    args.library_root = [checked_path(p, True) for p in args.library_root]
    manifest = prepare(args)
    print(json.dumps({'output': manifest['output'], 'manifest_sha256':
                     sha(Path(manifest['output']) / 'sealed/inputs-manifest.json')}, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(2)
