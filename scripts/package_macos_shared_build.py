#!/usr/bin/env python3
"""Package a verified published shared build, including its locked runtime inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from package_macos_shared_core import publish_absent


def check_paths(parser, args):
    if args.output_app.is_symlink():
        parser.error('output must not be a symbolic link')
    output = args.output_app.resolve()
    protected = [args.input_app.resolve(), args.work.resolve(), args.published.resolve(),
                 args.recipe.resolve(), Path(__file__).resolve().parents[1]]
    for path in protected:
        if output == path or output.is_relative_to(path) or path.is_relative_to(output):
            parser.error('output overlaps a protected input: ' + str(path))
    for path in [output, output.with_suffix('.shared-core.json'), output.with_suffix('.shared-backend.json')]:
        if path.exists() or path.is_symlink():
            parser.error('output or evidence already exists: ' + str(path))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish(staged_app, output):
    """Install sidecars, then publish the App with an exclusive rename."""
    installed = []
    try:
        for suffix in ('.shared-core.json', '.shared-backend.json'):
            source = staged_app.with_suffix(suffix)
            if source.is_symlink() or not source.is_file():
                raise ValueError('missing regular evidence sidecar: ' + str(source))
            source_stat = source.stat()
            destination = output.with_suffix(suffix)
            os.link(source, destination)
            installed.append((destination, source_stat.st_dev, source_stat.st_ino))
        publish_absent(staged_app, output)
    except BaseException:
        for path, device, inode in reversed(installed):
            try:
                current = path.lstat()
                if current.st_dev == device and current.st_ino == inode:
                    path.unlink()
            except OSError:
                # Preserve the publication error; never unlink by pathname alone.
                pass
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('input_app', 'output_app', 'work', 'published', 'recipe'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--check-paths', action='store_true')
    args = parser.parse_args()
    check_paths(parser, args)
    if args.check_paths:
        return
    work, published, recipe = (getattr(args, name).resolve() for name in ('work', 'published', 'recipe'))
    state = json.loads((work / 'build-state.json').read_text())
    identity = state['identity']
    package = json.loads((published / 'slice-manifest.json').read_text())
    if (identity['work_dir'] != str(work) or identity['output_dir'] != str(published)
            or identity['architectures'] != ['arm64', 'x86_64']
            or state['publication'] != package):
        parser.error('published build is not bound to the selected universal build state')
    canonical = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if package['build_identity_sha256'] != canonical:
        parser.error('published build identity digest is inconsistent')
    for filename, key in (('build_macos.py', 'builder_sha256'), ('prepare.py', 'preparer_sha256'),
                          ('verify_source.py', 'verifier_sha256'), ('manifest.json', 'manifest_sha256'),
                          ('mpv-0.41-shared-core.patch', 'patch_sha256')):
        if sha(recipe / filename) != identity[key]:
            parser.error('build recipe identity changed: ' + filename)
    files = {}
    for path in published.rglob('*'):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            parser.error('unsupported published output entry: ' + str(path))
        if path.is_file() and path != published / 'slice-manifest.json':
            files[path.relative_to(published).as_posix()] = sha(path)
    if files != package['files']:
        parser.error('published file set or content differs from the build state')
    verified = json.loads(subprocess.check_output([
        sys.executable, str(recipe / 'verify_source.py'), identity['archive'], str(work / 'source')], text=True))
    if verified != state['verified_source'] or verified != package['source']:
        parser.error('complete prepared source differs from the published build')
    frameworks = (args.input_app / 'Contents/Frameworks').resolve()
    # The input application must contain the exact libraries compiled against,
    # not merely libraries with matching sonames or nominal versions.
    for architecture in ('arm64', 'x86_64'):
        for library in identity['dependencies']['architectures'][architecture]['libraries'].values():
            install_id = library['install_dependencies'][0]
            if not install_id.startswith('@rpath/'):
                parser.error('runtime input has an unsupported install identity: ' + install_id)
            embedded = (frameworks / install_id.removeprefix('@rpath/')).resolve()
            if not embedded.is_relative_to(frameworks) or sha(embedded) != library['sha256']:
                parser.error('application runtime differs from the compiled dependency: ' + install_id)
    output = args.output_app.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.shared-package-', dir=output.parent) as staging:
        staged_app = Path(staging) / 'Candidate.app'
        package_candidate(args, published, recipe, work, package, verified, staged_app)
        check_paths(parser, args)
        publish(staged_app, output)


def package_candidate(args, published, recipe, work, package, verified, staged_app):
    subprocess.run([sys.executable, str(Path(__file__).with_name('package_macos_shared_core.py')),
        str(args.input_app), str(staged_app),
        str(published / 'arm64/libmpv.2.dylib'), str(published / 'x86_64/libmpv.2.dylib'),
        str(published / 'approved-slices.json'), '--prepared-source', str(work / 'source'),
        '--source-manifest', str(recipe / 'manifest.json')], check=True)
    record_path = staged_app.with_suffix('.shared-core.json')
    record = json.loads(record_path.read_text())
    record['published_build_manifest_sha256'] = sha(published / 'slice-manifest.json')
    record['build_identity_sha256'] = package['build_identity_sha256']
    record['complete_source'] = verified
    record['application_runtime_dependency_identity'] = 'exact-hash-match-both-architectures'
    record_path.write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
