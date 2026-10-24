#!/usr/bin/env python3
"""Rebuild the reviewed mpv's Intel slice with an explicit Swift target."""
import argparse
import json
import os
import pathlib
import shutil
import sys
import tarfile
import hashlib
import subprocess
import urllib.request

class BuildError(RuntimeError):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def run(command, *, env=None, log=None):
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if log is not None:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open('a') as stream:
            stream.write('$ ' + ' '.join(command) + '\n' + result.stdout)
    if result.returncode:
        raise BuildError(f'{command[0]} failed ({result.returncode}):\n{result.stdout[-4000:]}')
    return result.stdout


def download(url, path, expected):
    if not path.exists():
        partial = path.with_suffix(path.suffix + '.partial')
        with urllib.request.urlopen(url, timeout=60) as response, partial.open('wb') as stream:
            shutil.copyfileobj(response, stream)
        if sha256(partial) != expected:
            partial.unlink()
            raise BuildError(f'download checksum mismatch: {url}')
        partial.replace(path)
    if sha256(path) != expected:
        raise BuildError(f'cached checksum mismatch: {path}')

MPV_SHA = 'ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209'
FFMPEG_SHA = 'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635'
ASS_SHA = '5ba42655d7e8c5e87bba3ffc8a2b1bc19c29904240126bb0d4b924f39429219f'
ARCHIVE_SHA = '2965439e9d239a441263288140b2d8b09ee877478084916f63575a1775de97a4'


def extract(archive, destination, headers_only=False):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        if headers_only:
            members = [m for m in members if m.name.endswith('.h') and
                       m.name.split('/')[1] in FFMPEG_VERSIONS]
        # These checks also work on Python 3.11 without the new data filter.
        for member in members:
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination.resolve()) or member.issym() or member.islnk():
                raise BuildError(f'unsafe archive member: {member.name}')
        stream.extractall(destination, members=members)


FFMPEG_VERSIONS = dict(zip(
    ('libavcodec', 'libavformat', 'libavfilter', 'libavutil', 'libswresample', 'libswscale'),
    ('63.1.101', '63.1.101', '12.1.101', '61.1.101', '7.1.101', '10.1.101')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('archive', type=pathlib.Path)
    parser.add_argument('runtime_work', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--jobs', type=int, default=4, choices=range(1, 5))
    args = parser.parse_args()
    app, archive, runtime, output = [p.resolve() for p in
                                   (args.app, args.archive, args.runtime_work, args.output)]
    if sha256(archive) != ARCHIVE_SHA:
        raise BuildError('unreviewed mpv archive')
    prefix = runtime / 'x86_64'
    if not (prefix / 'lib/pkgconfig/libplacebo.pc').is_file():
        raise BuildError('build the matching universal runtime first')
    if output.exists() or output.with_suffix('.json').exists():
        raise BuildError(f'output already exists: {output}')
    work = runtime / 'mpv-intel'
    source, logs = work / 'sources', work / 'logs'
    source.mkdir(parents=True, exist_ok=True)
    pinned = (
        ('mpv.tar.gz', 'https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz', MPV_SHA),
        ('ffmpeg.tar.xz', 'https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz', FFMPEG_SHA),
        ('libass.tar.gz', 'https://github.com/libass/libass/archive/refs/tags/0.17.1.tar.gz', ASS_SHA),
    )
    for name, url, checksum in pinned:
        download(url, source / name, checksum)
        extract(source / name, source, name.startswith('ffmpeg'))
    libraries = work / 'archive'
    extract(archive, libraries)
    libraries /= 'libmpv-libs_develop_macos-universal-video-default'
    include, pc = work / 'include', work / 'pkgconfig'
    pc.mkdir(parents=True, exist_ok=True)
    for name, version in FFMPEG_VERSIONS.items():
        shutil.copytree(source / 'ffmpeg-9.0.1' / name, include / name, dirs_exist_ok=True)
        (pc / f'{name}.pc').write_text(
            f'includedir={include}\nName: {name}\nDescription: Reviewed FFmpeg 9.0.1\n'
            f'Version: {version}\nLibs: {libraries}/{name}.dylib\nCflags: -I${{includedir}}\n')
    (include / 'libavutil/avconfig.h').write_text(
        '#ifndef AVUTIL_AVCONFIG_H\n#define AVUTIL_AVCONFIG_H\n'
        '#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n#endif\n')
    (include / 'libavutil/ffversion.h').write_text('#define FFMPEG_VERSION "9.0.1"\n')
    (include / 'ass').mkdir(exist_ok=True)
    for name in ('ass.h', 'ass_types.h'):
        shutil.copy2(source / 'libass-0.17.1/libass' / name, include / 'ass' / name)
    # This installed header API is exactly the archive's uchardet version.
    brew = pathlib.Path(run(['brew', '--prefix', 'uchardet']).strip())
    if run(['pkg-config', '--modversion', 'uchardet']).strip() != '0.0.8':
        raise BuildError('uchardet headers must be version 0.0.8')
    shutil.copy2(brew / 'include/uchardet/uchardet.h', include / 'uchardet.h')
    ass = app / 'Contents/Frameworks/Ass.framework/Versions/A/Ass'
    if not ass.is_file():
        raise BuildError(f'missing embedded libass: {ass}')
    ass_identity = sha256(ass)
    ass_install_name = '@rpath/Ass.framework/Versions/A/Ass'
    for arch in ('arm64', 'x86_64'):
        if run(['otool', '-arch', arch, '-D', str(ass)]).splitlines()[-1].strip() != ass_install_name:
            raise BuildError('unexpected embedded libass install name')
    for name, version, library in (
            ('libass', '0.17.1', ass), ('uchardet', '0.0.8', libraries / 'libuchardet.dylib')):
        (pc / f'{name}.pc').write_text(
            f'includedir={include}\nName: {name}\nDescription: Reviewed library\n'
            f'Version: {version}\nLibs: {library}\nCflags: -I${{includedir}}\n')
    python = shutil.which('python3.11')
    if python is None:
        raise BuildError('python3.11 required for pinned source build tools')
    cross = work / 'cross.ini'
    cross.write_text(
        f"[binaries]\npython = '{python}'\n"
        "c = ['clang', '-arch', 'x86_64']\ncpp = ['clang++', '-arch', 'x86_64']\n"
        "objc = ['clang', '-arch', 'x86_64']\nar = 'ar'\nstrip = 'strip'\n"
        "pkg-config = 'pkg-config'\n[host_machine]\nsystem = 'darwin'\n"
        "cpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n"
        "[properties]\nneeds_exe_wrapper = true\n[built-in options]\n"
        "c_args = ['-mmacosx-version-min=12.0']\n"
        "cpp_args = ['-mmacosx-version-min=12.0']\n"
        "objc_args = ['-mmacosx-version-min=12.0']\n"
        "c_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=12.0']\n"
        "objc_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=12.0']\n"
        "cpp_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=12.0']\n")
    native = work / 'native.ini'
    native.write_text(f"[binaries]\npython = '{python}'\n")
    env = os.environ.copy()
    env.update(PKG_CONFIG_PATH='', PKG_CONFIG_LIBDIR=f'{pc}:{prefix}/lib/pkgconfig')
    build = work / 'build'
    command = ['meson', 'setup', str(build), str(source / 'mpv-0.41.0'),
               '--cross-file', str(cross), '--native-file', str(native),
               '--buildtype=release', '--auto-features=disabled', '-Dcplayer=false',
               '-Dlibmpv=true', '-Dtests=false', '-Db_lundef=true']
    for feature in ('cocoa', 'coreaudio', 'avfoundation', 'gl', 'gl-cocoa',
                    'plain-gl', 'videotoolbox-gl', 'swift-build', 'iconv', 'uchardet', 'zlib'):
        command.append(f'-D{feature}=enabled')
    command.append(f'-Dswift-flags=-target x86_64-apple-macosx12.0 -Xcc -fmodules-cache-path={work}/swift-cache')
    if (build / 'meson-private/coredata.dat').exists():
        command.insert(2, '--wipe')
    run(command, env=env, log=logs / 'configure.log')
    run(['meson', 'compile', '-C', str(build), f'-j{args.jobs}'], env=env, log=logs / 'build.log')
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(build / 'libmpv.2.dylib', output)
    run(['install_name_tool', '-id', '@rpath/Mpv.framework/Versions/A/Mpv', str(output)])
    run(['install_name_tool', '-change', str(prefix / 'lib/libplacebo.349.dylib'),
         '@rpath/libplacebo.dylib', str(output)])
    if run(['lipo', '-archs', str(output)]).strip() != 'x86_64':
        raise BuildError('rebuilt mpv is not x86_64')
    output.with_suffix('.json').write_text(json.dumps({
        'schema': 1, 'mpv': '0.41.0', 'mpv_source_sha256': MPV_SHA,
        'ffmpeg_source_sha256': FFMPEG_SHA, 'libass_source_sha256': ASS_SHA,
        'reviewed_archive_sha256': ARCHIVE_SHA, 'slice_sha256': sha256(output),
        'ass_binary_sha256': ass_identity, 'ass_install_name': ass_install_name,
    }, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (BuildError, OSError) as error:
        sys.exit(f'FAIL: {error}')
