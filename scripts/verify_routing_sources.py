#!/usr/bin/env python3
"""Verify App package resolution uses one current media-kit source checkout."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
from urllib.parse import unquote, urljoin, urlparse

PACKAGES = {
    'media_kit': 'media_kit',
    'media_kit_video': 'media_kit_video',
    'media_kit_android_dataspace_vendor': 'libs/android/media_kit_android_dataspace_vendor',
    'media_kit_libs_android_video': 'libs/android/media_kit_libs_android_video',
    'media_kit_libs_ios_video': 'libs/ios/media_kit_libs_ios_video',
    'media_kit_libs_macos_video': 'libs/macos/media_kit_libs_macos_video',
    'media_kit_libs_linux': 'libs/linux/media_kit_libs_linux',
    'media_kit_libs_ohos': 'libs/ohos/media_kit_libs_ohos',
    'media_kit_libs_video': 'libs/universal/media_kit_libs_video',
    'media_kit_libs_windows_video': 'libs/windows/media_kit_libs_windows_video',
}


def verify(config: Path, media_root: Path) -> dict[str, str]:
    config, media_root = config.resolve(strict=True), media_root.resolve(strict=True)
    entries = json.loads(config.read_text(encoding='utf-8'))['packages']
    found: dict[str, str] = {}
    for entry in entries:
        name = entry['name']
        if not name.startswith('media_kit'):
            continue
        if name not in PACKAGES:
            raise ValueError(f'Unaccounted media-kit package: {name}')
        if name in found:
            raise ValueError(f'Duplicate package: {name}')
        uri = urlparse(urljoin(config.as_uri(), entry['rootUri']))
        if uri.scheme != 'file' or uri.netloc not in ('', 'localhost'):
            raise ValueError(f'Non-local package root: {name}')
        actual = Path(unquote(uri.path)).resolve(strict=True)
        expected = (media_root / PACKAGES[name]).resolve(strict=True)
        expected.relative_to(media_root)  # Reject an escaped checkout symlink.
        if actual != expected or not actual.is_dir():
            raise ValueError(f'{name} does not use the supplied media-kit checkout')
        found[name] = PACKAGES[name]
    missing = set(PACKAGES) - set(found)
    if missing:
        raise ValueError('Missing media-kit packages: ' + ', '.join(sorted(missing)))
    return found


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-root', type=Path, required=True)
    parser.add_argument('--media-kit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    app, media = args.app_root.resolve(), args.media_kit_root.resolve()
    packages = verify(app / '.dart_tool/package_config.json', media)
    receipt = {
        'taskId': 'MK-ROUTING-20261011',
        'scope': 'app-source-package-resolution',
        'appCommit': git(app, 'rev-parse', 'HEAD'),
        'mediaKitCommit': git(media, 'rev-parse', 'HEAD'),
        'appSourceTree': git(app, 'rev-parse', 'HEAD^{tree}'),
        'mediaKitSourceTree': git(media, 'rev-parse', 'HEAD^{tree}'),
        'packages': packages,
        'nativeBinaryProvenanceVerified': False,
        'deviceTest': False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
