#!/usr/bin/env python3
"""Verify actual final-bundle shared backend creation; no visible-output claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('prepared_source', type=Path)
    parser.add_argument('source_manifest', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    source = args.prepared_source.resolve()
    manifest = json.loads(args.source_manifest.read_text())
    required = {'meson.build', 'video/out/libmpv.h', 'video/out/vo_gpu_next.c', 'video/out/vo_libmpv.c'}
    required.update('video/out/gpu_next/' + name + suffix
        for name in ('frame', 'hwdec', 'libmpv_gl_pl', 'libmpv_gpu_next', 'renderer', 'target')
        for suffix in ('.c', '.h'))
    if set(manifest['files']) != required:
        parser.error('source manifest must cover the complete 16-file shared core')
    for name, hashes in manifest['files'].items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != hashes['after']:
            parser.error('prepared shared source differs from manifest: ' + name)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        if plistlib.load(stream).get('MediaKitSharedRenderer') is not True:
            parser.error('candidate must explicitly enable the shared renderer')
    frameworks = app / 'Contents/Frameworks'
    library = frameworks / 'Mpv.framework/Versions/A/Mpv'
    probe = Path(__file__).parent / 'native/shared_backend_probe.c'
    results = {}
    record = {'framework_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
        'manifest_sha256': hashlib.sha256(args.source_manifest.read_bytes()).hexdigest(),
        'probe_sha256': hashlib.sha256(probe.read_bytes()).hexdigest(),
        'backend_creation_and_empty_target_render': results,
        'video_content_acceptance': 'pending', 'visible_acceptance': 'pending'}
    def save():
        if args.report:
            args.report.write_text(json.dumps(record, indent=2) + '\n')
    save()
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('DYLD_')}
    environment['PPX_EXPECTED_MPV_IMAGE'] = str(library.resolve())
    with tempfile.TemporaryDirectory(prefix='ppx-shared-backend-') as temporary:
        for architecture in ('arm64', 'x86_64'):
            binary = Path(temporary) / architecture
            subprocess.run(['xcrun', 'clang', '-arch', architecture,
                '-mmacosx-version-min=12.0', '-I', str(source / 'include'),
                '-I', str(source), str(probe), '-F', str(frameworks),
                '-framework', 'Mpv', '-framework', 'OpenGL',
                '-Wl,-rpath,' + str(frameworks), '-Wno-deprecated-declarations',
                '-o', str(binary)], check=True)
            subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
            # A timeout is a failed observation, never a passing result.
            try:
                result = subprocess.run(['/usr/bin/arch', '-' + architecture, str(binary)],
                    capture_output=True, text=True, timeout=60, env=environment)
            except subprocess.TimeoutExpired as error:
                results[architecture] = {'status': 'observation-timeout',
                    'stdout': (error.stdout or b'').decode(errors='replace') if isinstance(error.stdout, bytes) else error.stdout,
                    'stderr': (error.stderr or b'').decode(errors='replace') if isinstance(error.stderr, bytes) else error.stderr}
                save()
                for output in (error.stdout, error.stderr):
                    if output:
                        print(output.decode(errors='replace') if isinstance(output, bytes) else output, end='')
                print(json.dumps({'architecture': architecture, 'status': 'observation-timeout'}))
                raise
            print(result.stdout + result.stderr, end='')
            results[architecture] = {'exit_code': result.returncode,
                'stdout': result.stdout, 'stderr': result.stderr}
            save()
            if result.returncode:
                print(json.dumps({'architecture': architecture, **results[architecture]}, indent=2))
                raise subprocess.CalledProcessError(result.returncode, result.args)
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
