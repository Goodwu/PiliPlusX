#!/usr/bin/env python3
"""Fail closed if any media-kit package resolves outside the pinned fork SHA."""

from __future__ import annotations

import argparse
import re
import hashlib
import json
import subprocess

from prepare_routing_ci import package_roots
from verify_routing_sources import PACKAGES, verify
from pathlib import Path


PACKAGE_RE = re.compile(r"^  (media_kit(?:[^:]*)):\n((?:    .*\n|\n)*)", re.MULTILINE)


def verify_routing_lock(lockfile, source, variant, media, receipt, app_commit, media_commit):
    source, variant, media = source.resolve(), variant.resolve(), media.resolve()
    for root, expected in ((source, app_commit), (media, media_commit)):
        if not re.fullmatch('[0-9a-f]{40}', expected) or subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip() != expected:
            raise ValueError('routing lock source HEAD mismatch')
    if receipt.get('status') not in ('prepared','finalized') or receipt.get('appCommit') != app_commit or receipt.get('mediaKitCommit') != media_commit or receipt.get('variantRoot') != str(variant) or receipt.get('sourceRoot') != str(source) or receipt.get('mediaKitRoot') != str(media):
        raise ValueError('routing lock variant receipt identity mismatch')
    if lockfile.resolve() != variant/'pubspec.lock' or hashlib.sha256(lockfile.read_bytes()).hexdigest() != receipt.get('afterHashes',{}).get('pubspec.lock'):
        raise ValueError('routing lock changed from exact tracked variant bytes')
    original=subprocess.check_output(['git','-C',str(source),'cat-file','blob','HEAD:pubspec.lock'])
    if lockfile.read_bytes() != original:
        raise ValueError('routing lock differs from exact source commit blob')
    matches=list(PACKAGE_RE.finditer(lockfile.read_text()))
    if {m.group(1) for m in matches} != set(PACKAGES) or len(matches) != len(PACKAGES):
        raise ValueError('routing lock requires exactly the ten accounted media-kit packages')
    for match in matches:
        name,body=match.groups()
        expected=f'../media-kit/{PACKAGES[name]}'
        paths=re.findall(r'^      path: ["\']?([^"\'\n]+)["\']?$',body,re.M)
        if '    source: path\n' not in body or '      relative: true\n' not in body or paths != [expected] or (variant/expected).resolve() != (media/PACKAGES[name]).resolve():
            raise ValueError('routing lock source/path mismatch: '+name)
    config=variant/'.dart_tool/package_config.json'
    verify(config,media)
    actual=package_roots(config,[variant,media,Path(receipt['flutterRoot']),Path(receipt['pubCache'])])
    if actual != receipt.get('packageRoots') or actual.get('piliplus') != str(variant):
        raise ValueError('routing lock package roots changed')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("lockfile", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--mode", choices=("production", "routing"), default="production")
    for name in ("source-app-root", "variant-root", "media-kit-root", "variant-receipt"):
        parser.add_argument("--" + name, type=Path)
    parser.add_argument("--app-commit")
    parser.add_argument("--url", default="https://github.com/Goodwu/media-kit.git")
    args = parser.parse_args()

    if args.mode == 'routing':
        if any(value is None for value in (args.source_app_root,args.variant_root,args.media_kit_root,args.variant_receipt,args.app_commit)):
            parser.error('routing mode requires source/variant/media roots, receipt and App SHA')
        verify_routing_lock(args.lockfile,args.source_app_root,args.variant_root,args.media_kit_root,json.loads(args.variant_receipt.read_text()),args.app_commit,args.commit)
        print('routing media-kit lock verified: exact sources and prepared variant')
        return
    text = args.lockfile.read_text(encoding="utf-8")
    matches = list(PACKAGE_RE.finditer(text))
    if not matches:
        raise SystemExit("no media-kit packages found in lockfile")

    failures: list[str] = []
    for match in matches:
        name, body = match.group(1), match.group(2)
        if "    source: git\n" not in body:
            failures.append(f"{name}: source is not git")
            continue
        resolved = re.search(r"^      resolved-ref: (.+)$", body, re.MULTILINE)
        url = re.search(r'^      url: "([^"]+)"$', body, re.MULTILINE)
        resolved_value = (
            resolved.group(1).strip().strip('"').strip("'")
            if resolved
            else None
        )
        if not resolved or resolved_value != args.commit:
            failures.append(f"{name}: resolved-ref is not {args.commit}")
        if not url or url.group(1) != args.url:
            failures.append(f"{name}: url is not {args.url}")

    if failures:
        raise SystemExit("media-kit lock verification failed:\n" + "\n".join(failures))
    print(f"media-kit lock verified: {len(matches)} packages at {args.commit}")


if __name__ == "__main__":
    main()
