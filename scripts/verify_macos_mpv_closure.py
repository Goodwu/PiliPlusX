#!/usr/bin/env python3
"""Check that the media runtime closure is complete and contained in the App."""
import pathlib
import plistlib
import subprocess
import sys


SYSTEM_PREFIXES = ('/System/Library/', '/usr/lib/')


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def architectures(binary):
    result = command('lipo', '-archs', str(binary)).split()
    if not result or len(result) != len(set(result)):
        raise ValueError(f'empty or invalid architecture set: {binary.name}')
    return set(result)


def minimum_macos(binary, arch):
    field = None
    for line in command('otool', '-arch', arch, '-l', str(binary)).splitlines():
        parts = line.split()
        if parts[:1] == ['cmd']:
            field = {'LC_BUILD_VERSION': 'minos',
                     'LC_VERSION_MIN_MACOSX': 'version'}.get(parts[1])
        elif field and parts[:1] == [field]:
            version = tuple(int(part) for part in parts[1].split('.'))
            return version + (0,) * (3 - len(version))
    raise ValueError(f'{arch} macOS deployment target missing: {binary.name}')


def dependency_names(binary, arch):
    rows = command('otool', '-arch', arch, '-L', str(binary)).splitlines()[1:]
    dependencies = []
    for line in rows:
        if not line.strip():
            continue
        name, marker, _metadata = line.strip().partition(' (compatibility ')
        if not marker or not name:
            raise ValueError(f'unrecognized {arch} dependency row in {binary.name}: {line!r}')
        dependencies.append(name)
    return dependencies


def contained_file(path, app, description):
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValueError(f'missing {description}: {path}') from error
    if not resolved.is_relative_to(app):
        raise ValueError(f'{description} escapes application bundle: {path} -> {resolved}')
    if not resolved.is_file():
        raise ValueError(f'{description} is not a regular file: {resolved}')
    return resolved


def verify(app_path):
    app = app_path.resolve(strict=True)
    frameworks = app / 'Contents/Frameworks'
    with (app / 'Contents/Info.plist').open('rb') as info:
        executable_name = plistlib.load(info).get('CFBundleExecutable')
    if (not isinstance(executable_name, str) or not executable_name
            or '/' in executable_name or executable_name in ('.', '..')):
        raise ValueError('invalid application executable name')
    executable = contained_file(app / 'Contents/MacOS' / executable_name, app,
                                'application executable')
    arches = architectures(executable)
    for arch in sorted(arches):
        deployment = minimum_macos(executable, arch)
        pending = [frameworks / 'Mpv.framework/Versions/A/Mpv']
        pending += [frameworks / name for name in (
            'libplacebo.dylib', 'libvulkan.1.dylib', 'libshaderc_shared.1.dylib')]
        seen = set()
        while pending:
            candidate = pending.pop()
            binary = contained_file(candidate, app, 'runtime dependency')
            if binary in seen:
                continue
            seen.add(binary)
            if arch not in architectures(binary):
                raise ValueError(f'{arch} missing from {binary.name}')
            required = minimum_macos(binary, arch)
            if required > deployment:
                raise ValueError(f'{arch} {binary.name} requires macOS {required}, '
                                 f'above application target {deployment}')
            for dependency in dependency_names(binary, arch):
                if dependency.startswith(SYSTEM_PREFIXES):
                    continue
                if dependency.startswith('@rpath/'):
                    target = frameworks / dependency[len('@rpath/'):]
                elif dependency.startswith('@loader_path/'):
                    target = binary.parent / dependency[len('@loader_path/'):]
                elif dependency.startswith('@executable_path/'):
                    target = executable.parent / dependency[len('@executable_path/'):]
                else:
                    raise ValueError(f'nonrelocatable dependency: {dependency}')
                pending.append(target)
        print(f'PASS: {arch} runtime closure ({len(seen)} binaries)')


def main(argv=None):
    try:
        if argv is None:
            argv = sys.argv[1:]
        if len(argv) != 1:
            raise ValueError('usage: verify_macos_mpv_closure.py APP')
        verify(pathlib.Path(argv[0]))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'FAIL: {error}')


if __name__ == '__main__':
    main()
