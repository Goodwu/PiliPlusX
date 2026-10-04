#!/usr/bin/env python3
"""Build and package a separate opt-in shared macOS candidate.

Normal CI/ensure remain unchanged. This entry requires explicit, sealed inputs;
it never launches the app or claims video/display acceptance. Real execution
includes the existing serial backend capability probes during packaging.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ARCHES = ('arm64', 'x86_64')
SUFFIXES = ('.shared-core.json', '.shared-backend.json')
RECIPE_KEYS = {'build_macos.py': 'builder_sha256', 'prepare.py': 'preparer_sha256',
               'verify_source.py': 'verifier_sha256', 'manifest.json': 'manifest_sha256',
               'mpv-0.41-shared-core.patch': 'patch_sha256'}


def fail(message):
    raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def path_checked(value, directory=None, must_exist=True):
    p = Path(value).expanduser().absolute()
    for q in (p, *p.parents):
        if q.is_symlink():
            fail(f'symlink path component is forbidden: {q}')
    if must_exist:
        if directory is True and not p.is_dir():
            fail(f'missing directory: {p}')
        if directory is False and not p.is_file():
            fail(f'missing regular file: {p}')
        if not p.exists():
            fail(f'missing path: {p}')
    elif p.exists() and not (p.is_dir() or p.is_file()):
        fail(f'unsupported existing output: {p}')
    resolved = p.resolve(strict=must_exist)
    if any(c in str(resolved) for c in ('\n', '\r', ':', "'", '"')):
        fail(f'unsupported path characters: {resolved}')
    return resolved


def app_tree(root):
    """Hash regular files, modes, directories and internal symlink targets."""
    root = path_checked(root, True)
    result = {}
    def walk(directory):
        for p in sorted(directory.iterdir()):
            relative = p.relative_to(root).as_posix()
            mode = p.lstat().st_mode
            if stat.S_ISLNK(mode):
                target = os.readlink(p)
                try:
                    resolved = p.resolve(strict=True)
                except (OSError, RuntimeError):
                    fail(f'broken or cyclic application symlink: {p}')
                if not resolved.is_relative_to(root):
                    fail(f'application symlink escapes its root: {p}')
                result[relative] = {'type': 'symlink', 'target': target}
            elif stat.S_ISREG(mode):
                result[relative] = {'type': 'file', 'mode': stat.S_IMODE(mode), 'sha256': sha(p)}
            elif stat.S_ISDIR(mode):
                result[relative] = {'type': 'directory', 'mode': stat.S_IMODE(mode)}
                walk(p)
            else:
                fail(f'unsafe special application entry: {p}')
    walk(root)
    if not result:
        fail('application is empty')
    return result


def overlap(a, b):
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def preflight(args):
    for name in ('input_app', 'inputs', 'recipe'):
        setattr(args, name, path_checked(getattr(args, name), True))
    for name in ('work_dir', 'published_dir', 'output_app', 'log_dir'):
        setattr(args, name, path_checked(getattr(args, name), must_exist=False))
    if args.input_app.suffix != '.app' or args.output_app.suffix != '.app':
        fail('input/output must be explicit .app paths')
    if not args.output_app.parent.is_dir() or not args.log_dir.parent.is_dir():
        fail('candidate and log parent directories must already exist')
    outputs = [args.output_app, *(args.output_app.with_suffix(s) for s in SUFFIXES)]
    if any(os.path.lexists(p) for p in [*outputs, args.log_dir]):
        fail('candidate, sidecar or log output already exists')
    protected = [args.input_app, args.inputs, args.recipe.parent.parent, HERE.parent]
    owned = [args.work_dir, args.published_dir, args.log_dir, *outputs]
    for p in owned:
        if any(overlap(p, q) for q in protected):
            fail(f'owned path overlaps a protected repository/input: {p}')
        if any(part.endswith('.app') for part in p.parts[:-1]):
            fail(f'owned path is inside another application: {p}')
    for i, p in enumerate(owned):
        if any(overlap(p, q) for q in owned[i + 1:]):
            fail('work/published/candidate/log paths must be independent')
    if args.resume:
        if not (args.work_dir / 'build-state.json').is_file():
            fail('resume requires existing shared-builder state')
    elif args.work_dir.exists() or args.published_dir.exists():
        fail('fresh candidate requires absent build work and published directories')


def run_step(command, log):
    env = os.environ.copy()
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    for key in list(env):
        if key.startswith('DYLD_') or key in ('PYTHONPATH', 'PYTHONHOME'):
            env.pop(key, None)
    start = time.monotonic()
    with log.open('x') as stream:
        stream.write('COMMAND ' + json.dumps([str(x) for x in command]) + '\n')
        stream.flush()
        result = subprocess.run([str(x) for x in command], stdout=stream,
                                stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        fail(f'command failed ({result.returncode}); log: {log}')
    return {'exit_code': result.returncode, 'seconds': time.monotonic() - start}


def verify_inputs(args, name):
    run_step([sys.executable, HERE / 'prepare_macos_shared_inputs.py', '--verify',
              args.inputs, '--recipe', args.recipe], args.log_dir / (name + '.log'))
    manifest_path = args.inputs / 'sealed/inputs-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    lock = json.loads((args.inputs / 'sealed/dependency-lock.json').read_text())
    if manifest.get('output') != str(args.inputs) or lock.get('schema_version') != 1:
        fail('sealed inputs identity differs from the selected path')
    return {'manifest_sha256': sha(manifest_path), 'manifest': manifest, 'lock': lock}


def validate_input_app(args, builder):
    with path_checked(args.input_app / 'Contents/Info.plist', False).open('rb') as stream:
        info = plistlib.load(stream)
    executable = info['CFBundleExecutable']
    if not isinstance(executable, str) or '/' in executable or executable in ('.', '..'):
        fail('invalid source application executable')
    runner = path_checked(args.input_app / 'Contents/MacOS' / executable, False)
    if set(builder.output(['lipo', '-archs', runner]).split()) != set(ARCHES):
        fail('candidate requires a universal arm64+x86_64 source Runner')
    plugin = args.input_app / 'Contents/Frameworks/media_kit_video.framework/Versions/A/media_kit_video'
    bridge = path_checked(plugin, False) if plugin.is_file() else runner
    with tempfile.TemporaryDirectory(prefix='.bridge-check-', dir=args.log_dir) as temporary:
        for arch in ARCHES:
            thin = Path(temporary) / arch
            run_step(['lipo', bridge, '-thin', arch, '-output', thin],
                     args.log_dir / ('source-bridge-' + arch + '.log'))
            if b'MediaKitSharedRenderer' not in thin.read_bytes():
                fail(f'{arch} source application lacks reviewed shared bridge')
    run_step(['codesign', '--verify', '--deep', '--strict', args.input_app],
             args.log_dir / 'source-app-signature.log')
    return {'runner_sha256': sha(runner), 'bridge_sha256': sha(bridge),
            'bridge_marker': 'present-both-architectures; static-only'}


def library_plan(inputs, lock):
    """Both ABI records must name the same signed universal whole files."""
    by_arch = {}
    for arch in ARCHES:
        records = lock['architectures'][arch]['libraries']
        indexed = {}
        for source, entry in records.items():
            p = path_checked(source, False)
            if str(p) != source or not p.is_relative_to(inputs / 'lib'):
                fail('locked runtime path is noncanonical or outside prepared lib/')
            if set(entry['architectures']) != set(ARCHES) or sha(p) != entry['sha256']:
                fail('runtime must match the signed universal whole-file SHA and both ABIs')
            install_id = entry['install_dependencies'][0]
            if not install_id.startswith('@rpath/'):
                fail('unsupported runtime install ID')
            relative = PurePosixPath(install_id[7:])
            if (relative.is_absolute() or '..' in relative.parts or
                    install_id != '@rpath/' + relative.as_posix() or '\\' in install_id):
                fail('unsafe or noncanonical runtime install ID')
            parts = relative.parts
            if len(parts) == 1 and parts[0].endswith('.dylib'):
                framework = None
            elif (len(parts) == 4 and parts[0].endswith('.framework') and
                  parts[1:3] == ('Versions', 'A') and parts[3] == parts[0][:-10]):
                framework = parts[0]
            else:
                fail(f'unsupported runtime layout: {install_id}')
            if install_id in indexed:
                fail(f'duplicate runtime install ID: {install_id}')
            expected_source = inputs / 'lib' / relative.as_posix()
            if p != expected_source:
                fail('locked source path disagrees with its runtime install ID')
            indexed[install_id] = {'source': str(p), 'relative': relative.as_posix(),
                                  'sha256': entry['sha256'], 'framework': framework}
        if not indexed:
            fail('empty locked runtime closure')
        by_arch[arch] = indexed
    if by_arch['arm64'] != by_arch['x86_64']:
        fail('architecture runtime closures differ in whole-file identity')
    return by_arch['arm64']


def validate_build(args, verified, builder):
    state = json.loads((args.work_dir / 'build-state.json').read_text())
    identity = state['identity']
    expected = {'archive': str(args.inputs / 'archive/mpv.tar.gz'),
                'archive_sha256': sha(args.inputs / 'archive/mpv.tar.gz'),
                'work_dir': str(args.work_dir), 'output_dir': str(args.published_dir),
                'architectures': list(ARCHES), 'jobs': args.jobs,
                'options': builder.OPTIONS, 'dependencies': verified['lock']}
    for key, value in expected.items():
        if identity.get(key) != value:
            fail(f'shared build state differs from selected sealed inputs/parameters: {key}')
    for filename, key in RECIPE_KEYS.items():
        if identity.get(key) != sha(args.recipe / filename):
            fail(f'shared build recipe identity differs: {filename}')
    actual_source = builder.verify_source(args.inputs / 'archive/mpv.tar.gz', args.work_dir / 'source')
    if actual_source != state['verified_source']:
        fail('shared build complete source tree changed')
    package = json.loads((args.published_dir / 'slice-manifest.json').read_text())
    if (state.get('publication') != package or package['build_identity_sha256'] != canonical(identity)
            or package['source'] != actual_source or package['architectures'] != list(ARCHES)):
        fail('published shared build is not bound to the validated state')
    if builder.publication_files(args.published_dir) != package['files']:
        fail('published shared build file set or SHA changed')
    return state


def destination_binary(app, relative):
    frameworks = path_checked(app / 'Contents/Frameworks', True)
    target = frameworks / relative
    for p in (target, *target.parents):
        if p == frameworks:
            break
        if p.is_symlink():
            fail(f'cannot replace an aliased runtime target: {p}')
    if not target.resolve(strict=False).is_relative_to(frameworks):
        fail('runtime destination escapes Frameworks')
    return target


def embed_runtime(args, stage, plan, builder):
    shutil.copytree(args.input_app, stage, symlinks=True, copy_function=shutil.copy2)
    if app_tree(stage) != app_tree(args.input_app):
        fail('independent application copy differs from input tree')
    for index, item in enumerate(plan.values()):
        target = destination_binary(stage, item['relative'])
        if item['framework']:
            framework = target.parents[2]
            if not target.is_file() or not (framework / 'Versions/A/Resources/Info.plist').is_file():
                fail(f'normal application lacks existing runtime framework metadata: {framework}')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item['source'], target)
        if sha(target) != item['sha256']:
            fail('embedding changed a locked runtime binary')
        signed_object = target.parents[2] if item['framework'] else target
        run_step(['codesign', '--verify', '--strict', signed_object],
                 args.log_dir / f'runtime-signature-{index}.log')
    verify_embedded(stage, plan, builder)


def runtime_signature_identity(args, stage, plan, builder, preparer):
    """Read exact locked bytes and both signed slices in their full contexts."""
    result = {}
    with tempfile.TemporaryDirectory(prefix='.runtime-signature-', dir=args.log_dir) as temporary:
        for index, (install_id, item) in enumerate(plan.items()):
            target = destination_binary(stage, item['relative'])
            if sha(target) != item['sha256']:
                fail('runtime bytes differ before envelope signature inspection')
            context = target.parents[2] if item['framework'] else target
            record = {'whole_sha256': sha(target), 'architectures': {}}
            for arch in ARCHES:
                signature = preparer.signature_state(target, arch, builder, context)
                if not signature['signed']:
                    fail('envelope signing requires an already valid signed runtime')
                thin = Path(temporary) / (str(index) + '-' + arch)
                builder.output(['lipo', target, '-thin', arch, '-output', thin])
                record['architectures'][arch] = {'thin_sha256': sha(thin),
                                                'signature': signature}
            result[install_id] = record
    return result


def sign_runtime_envelope(args, stage, plan, builder, preparer):
    """Sign only the private App envelope, proving locked libraries unchanged."""
    source_before = app_tree(args.input_app)
    verify_embedded(stage, plan, builder)
    before = runtime_signature_identity(args, stage, plan, builder, preparer)
    run_step(['codesign', '--force', '--sign', '-',
              '--preserve-metadata=entitlements,requirements,flags', stage],
             args.log_dir / 'runtime-app-envelope-sign.log')
    run_step(['codesign', '--verify', '--deep', '--strict', stage],
             args.log_dir / 'runtime-app-envelope-verify.log')
    verify_embedded(stage, plan, builder)
    after = runtime_signature_identity(args, stage, plan, builder, preparer)
    if after != before:
        fail('App envelope signing changed locked runtime whole/thin/signature identity')
    if app_tree(args.input_app) != source_before:
        fail('source application changed during private App envelope signing')
    record = {'policy': 'private-app-envelope-only-no-deep-sign',
              'before': before, 'after': after,
              'source_app_tree_sha256': canonical(source_before),
              'source_app_unchanged': True}
    (args.log_dir / 'runtime-envelope.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def verify_embedded(app, plan, builder):
    for install_id, item in plan.items():
        target = destination_binary(app, item['relative'])
        if not target.is_file() or sha(target) != item['sha256']:
            fail(f'embedded runtime whole-file SHA differs: {install_id}')
        for arch in ARCHES:
            identity = builder.library_identity(target, arch)
            if identity['install_dependencies'][0] != install_id:
                fail(f'embedded runtime install identity differs: {install_id}')


def publish_candidate(staged, output, publisher):
    """Exclusive sidecars first, app last; roll back only our own sidecar inodes."""
    destinations = [output, *(output.with_suffix(s) for s in SUFFIXES)]
    if any(os.path.lexists(p) for p in destinations):
        fail('candidate or sidecar appeared before exclusive publication')
    installed = []
    try:
        for suffix in SUFFIXES:
            source = staged.with_suffix(suffix)
            if source.is_symlink() or not source.is_file():
                fail('staged package is missing a regular evidence sidecar')
            dest = output.with_suffix(suffix)
            os.link(source, dest)
            installed.append((dest, dest.lstat().st_ino))
        publisher(staged, output)
    except BaseException:
        for path, inode in reversed(installed):
            if not path.is_symlink() and path.exists() and path.lstat().st_ino == inode:
                path.unlink()
        raise


def execute(args):
    preflight(args)
    args.log_dir.mkdir()
    result = {'candidate': str(args.output_app), 'input_app': str(args.input_app),
              'input_kind_claim': args.input_kind, 'visible_acceptance': 'pending',
              'video_content_acceptance': 'pending', 'production_default_enabled': False,
              'consumer_sha256': sha(Path(__file__))}
    try:
        preparer = load_module(HERE / 'prepare_macos_shared_inputs.py', 'candidate_preparer')
        builder = load_module(args.recipe / 'build_macos.py', 'candidate_builder')
        before = app_tree(args.input_app)
        result['input_app_tree_sha256'] = canonical(before)
        result['source_static_checks'] = validate_input_app(args, builder)
        verified = verify_inputs(args, 'inputs-before-build')
        plan = library_plan(args.inputs, verified['lock'])
        if args.resume:
            # Even an interrupted resume must match selected inputs before compile.
            state = json.loads((args.work_dir / 'build-state.json').read_text())
            if (state['identity'].get('dependencies') != verified['lock'] or
                    state['identity'].get('archive') != str(args.inputs / 'archive/mpv.tar.gz')):
                fail('resume state is bound to different sealed inputs')
        if args.check_inputs:
            if app_tree(args.input_app) != before:
                fail('source application changed during input checks')
            result.update(status='inputs-checked-only', runtime_library_count=len(plan))
            return result
        command = [sys.executable, args.recipe / 'build_macos.py', '--archive',
                   args.inputs / 'archive/mpv.tar.gz', '--work-dir', args.work_dir,
                   '--output-dir', args.published_dir, '--dependency-config',
                   args.inputs / 'sealed/dependency-config.json', '--dependency-lock',
                   args.inputs / 'sealed/dependency-lock.json', '--jobs', str(args.jobs)]
        if args.resume:
            command.append('--resume')
        result['build'] = run_step(command, args.log_dir / 'shared-build.log')
        state = validate_build(args, verified, builder)
        again = verify_inputs(args, 'inputs-before-package')
        if again != verified:
            fail('sealed inputs changed between build and packaging')
        # App and both sidecars stay private until all existing final gates pass.
        with tempfile.TemporaryDirectory(prefix='.' + args.output_app.stem + '.consumer-',
                                         dir=args.output_app.parent) as temporary:
            directory = Path(temporary)
            runtime_app = directory / 'Runtime.app'
            staged_app = directory / 'Packaged.app'
            embed_runtime(args, runtime_app, plan, builder)
            result['runtime_app_envelope'] = sign_runtime_envelope(
                args, runtime_app, plan, builder, preparer)
            if app_tree(args.input_app) != before:
                fail('source application changed during runtime staging')
            run_step([sys.executable, HERE / 'package_macos_shared_build.py', runtime_app,
                      staged_app, args.work_dir, args.published_dir, args.recipe],
                     args.log_dir / 'shared-package.log')
            verify_embedded(staged_app, plan, builder)
            run_step([HERE / 'verify_macos_mpv_bundle.sh', staged_app],
                     args.log_dir / 'final-bundle-gates.log')
            final_inputs = verify_inputs(args, 'inputs-after-package')
            if final_inputs != verified or app_tree(args.input_app) != before:
                fail('sealed inputs or source application changed before publication')
            result.update(status='staged-gates-passed',
                          sealed_inputs_manifest_sha256=verified['manifest_sha256'],
                          build_identity_sha256=canonical(state['identity']),
                          runtime_library_count=len(plan))
            evidence_path = staged_app.with_suffix('.shared-core.json')
            evidence = json.loads(evidence_path.read_text())
            evidence['candidate_consumer'] = result
            evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
            # Record final gate evidence outside the candidate before publication;
            # logs survive failures and are never mistaken for acceptance artifacts.
            (args.log_dir / 'staged-gates.json').write_text(json.dumps(result, indent=2) + '\n')
            with (staged_app / 'Contents/Info.plist').open('rb') as stream:
                final_info = plistlib.load(stream)
            if 'MediaKitSharedBootstrapPending' in final_info:
                fail('shared bootstrap remains pending before candidate publication')
            publish_candidate(staged_app, args.output_app, preparer.publish_absent)
        result['status'] = 'published-candidate'
        return result
    except BaseException as error:
        result.update(status='failed', error=str(error))
        raise
    finally:
        (args.log_dir / 'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('input_app', 'inputs', 'recipe', 'work_dir', 'published_dir', 'output_app', 'log_dir'):
        parser.add_argument('--' + name.replace('_', '-'), type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4, choices=range(1, 5))
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--check-inputs', action='store_true', help='CPU checks only; no build/package/backend probe')
    parser.add_argument('--input-kind', choices=('unknown', 'normal', 'diagnostic'), default='unknown',
                        help='caller claim recorded as such; never inferred from a filename')
    args = parser.parse_args(argv)
    result = execute(args)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(2)
