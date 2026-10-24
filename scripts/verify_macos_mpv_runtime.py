#!/usr/bin/env python3
"""Verify cached runtime content against its pinned build manifest."""
import json
import pathlib
import sys

from build_macos_mpv_runtime import SOURCE_ARCHIVES, LIBPLACEBO_COMMIT, VERSIONS, sha256

directory = pathlib.Path(sys.argv[1])
try:
    manifest = json.loads((directory / 'manifest.json').read_text())
    expected = {'libplacebo.dylib', 'libshaderc_shared.1.dylib',
                'libvulkan.1.dylib', 'liblcms2.2.dylib'}
    if manifest['schema'] != 1 or manifest['versions'] != VERSIONS:
        raise ValueError('runtime build versions mismatch')
    if manifest['sources']['libplacebo']['commit'] != LIBPLACEBO_COMMIT:
        raise ValueError('libplacebo source identity mismatch')
    hashes = {name: record[1] for name, record in SOURCE_ARCHIVES.items()}
    if manifest['sources']['source_archives_sha256'] != hashes:
        raise ValueError('runtime dependency source identity mismatch')
    if set(manifest['libraries']) != expected:
        raise ValueError('runtime library set mismatch')
    for name in expected:
        library = directory / name
        if library.is_symlink() or not library.is_file():
            raise ValueError(f'runtime library missing or symlink: {name}')
        if sha256(library) != manifest['libraries'][name]['sha256']:
            raise ValueError(f'runtime library checksum mismatch: {name}')
except (OSError, KeyError, TypeError, ValueError) as error:
    sys.exit(f'FAIL: {error}')
print('PASS: pinned universal runtime source and library identities')
