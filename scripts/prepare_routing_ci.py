#!/usr/bin/env python3
"""Prepare isolated routing source CI; this does not validate native binaries."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname

from verify_routing_sources import verify

BRANCH = 'refs/heads/routing/MK-ROUTING-20261011'


def within(path: Path, root: Path) -> bool:
    return path.resolve().is_relative_to(root.resolve())


def package_roots(config: Path, allowed: list[Path]) -> dict[str, str]:
    """Reject stale/shared roots, duplicates, URLs and symlink escapes."""
    roots: dict[str, str] = {}
    for entry in json.loads(config.read_text(encoding='utf-8'))['packages']:
        name = entry['name']
        if name in roots:
            raise ValueError(f'Duplicate package root: {name}')
        uri = urlparse(urljoin(config.resolve().as_uri(), entry['rootUri']))
        if uri.scheme != 'file' or uri.netloc not in ('', 'localhost') or uri.query or uri.fragment:
            raise ValueError(f'Non-local package root: {name}')
        root = Path(url2pathname(uri.path)).resolve(strict=True)
        if not root.is_dir() or not any(within(root, base) for base in allowed):
            raise ValueError(f'Package root escaped isolated sources: {name}: {root}')
        roots[name] = str(root)
    if not roots:
        raise ValueError('Empty package config')
    return roots


class Bootstrap:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.app = args.app_root.resolve(strict=True)
        self.media = args.media_kit_root.resolve(strict=True)
        self.private = args.private_root.resolve()
        self.output = args.output.resolve()
        temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
        if not within(self.private, temporary) or self.private == temporary or not within(self.output, self.private):
            raise ValueError('Private root/output must be children of RUNNER_TEMP')
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ)
        self.receipt: dict = {'scope': 'routing-source-bootstrap', 'nativeBinaryProvenanceVerified': False,
                              'deviceTest': False, 'platform': args.platform,
                              'platformPreconditions': ['App and SDK checkout use LF patch inputs',
                                                        'pointer-filter skip flag must be absent',
                                                        'pwsh and python3 must be available',
                                                        'fresh independent SDK and private pub cache'],
                              'steps': [], 'status': 'running'}

    def save(self) -> None:
        (self.output / 'bootstrap.json').write_text(json.dumps(self.receipt, indent=2) + '\n', encoding='utf-8')

    def run(self, label: str, command: list[str], cwd: Path) -> str:
        step = {'name': label, 'command': command, 'cwd': str(cwd)}
        self.receipt['steps'].append(step)
        self.save()
        try:
            result = subprocess.run(command, cwd=cwd, env=self.env, text=True, encoding='utf-8',
                                    errors='replace', stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            step['exitCode'] = result.returncode
            (self.output / f'{label}.log').write_text(result.stdout, encoding='utf-8')
            self.save()
            if result.returncode:
                raise RuntimeError(f'{label} failed with exit code {result.returncode}; see {label}.log')
            return result.stdout.strip()
        except OSError as error:
            step['launchError'] = str(error)
            self.save()
            raise

    def vector(self, phase: str) -> dict[str, str]:
        vector = {}
        for name, root, expected in [('app', self.app, self.args.expected_app_sha),
                                      ('media-kit', self.media, self.args.expected_media_kit_sha)]:
            if not re.fullmatch('[0-9a-f]{40}', expected):
                raise ValueError(f'{name} must have an exact 40-character SHA')
            head = self.run(f'{phase}-{name}-head', ['git', 'rev-parse', 'HEAD'], root)
            remote = self.run(f'{phase}-{name}-remote', ['git', 'ls-remote', '--exit-code', 'origin', BRANCH], root)
            lines = remote.splitlines()
            if head != expected or len(lines) != 1 or lines[0].split() != [expected, BRANCH]:
                raise ValueError(f'{name} source vector drift: expected {expected}, local {head}, remote {remote}')
            vector[name] = head
            vector[f'{name}Tree'] = self.run(f'{phase}-{name}-tree', ['git', 'rev-parse', 'HEAD^{tree}'], root)
        return vector

    def source_hashes(self) -> dict[str, str]:
        hashes = {}
        for name, root in [('app', self.app), ('media-kit', self.media)]:
            paths = self.run(f'{name}-tracked-files', ['git', 'ls-files', '-z'], root).split('\0')
            for relative in paths:
                if relative and (name == 'media-kit' or relative.startswith(('lib/', 'test/'))):
                    path = root / relative
                    if not path.is_file():
                        raise ValueError(f'Source file missing: {name}/{relative}')
                    hashes[f'{name}/{relative}'] = hashlib.sha256(path.read_bytes()).hexdigest()
        return hashes

    def check_sources(self) -> None:
        for name, root in [('app', self.app), ('media-kit', self.media)]:
            self.run(f'{name}-clean-input', ['git', 'diff', '--exit-code', 'HEAD', '--'], root)
            unknown = self.run(f'{name}-untracked-input', ['git', 'ls-files', '--others',
                               '--exclude-standard', '-z'], root)
            if unknown:
                raise ValueError(f'Untracked {name} input: {unknown.replace(chr(0), ", ")}')
            domains = ['lib', 'test'] if name == 'app' else [
                ':(glob)**/lib/**', ':(glob)**/test/**', ':(glob)**/src/**']
            ignored = self.run(f'{name}-ignored-source-input', ['git', 'ls-files', '--others',
                               '--ignored', '--exclude-standard', '-z', '--', *domains], root)
            for relative in ignored.split('\0'):
                # Python import caches are generated, non-source data. Ignore rules
                # alone must never authorize Dart/native/test source inputs.
                if relative and not ('__pycache__' in Path(relative).parts and relative.endswith('.pyc')):
                    raise ValueError(f'Untracked ignored {name} source input: {relative}')

    def check_patch_inputs(self) -> None:
        if self.env.get('PILIPLUSX_SKIP_POINTER_FILTER_PATCH') == '1':
            raise ValueError('Routing bootstrap requires the pointer-filter patch chain; skip flag refused')
        for directory in ('material', 'cupertino'):
            for path in (self.app / 'lib/scripts' / directory).glob('*.patch'):
                if b'\r\n' in path.read_bytes():
                    raise ValueError('Patch files require an LF checkout before bootstrap; '
                                     'set core.autocrlf=false/core.eol=lf before actions/checkout')

    def sdk_blob_hash(self, label: str, source: Path, revision: str, relative: str) -> dict:
        command = ['git', 'cat-file', 'blob', f'{revision}:{relative}']
        step = {'name': label, 'command': command, 'cwd': str(source)}
        self.receipt['steps'].append(step)
        self.save()
        try:
            result = subprocess.run(command, cwd=source, env=self.env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            step['exitCode'] = result.returncode
            (self.output / f'{label}.log').write_bytes(result.stderr)
            if result.returncode:
                return {'readError': f'git exited {result.returncode}; see {label}.log'}
            return {'sha256': hashlib.sha256(result.stdout).hexdigest(), 'bytes': len(result.stdout)}
        except OSError as error:
            step['launchError'] = str(error)
            return {'readError': str(error)}
        finally:
            self.save()

    def collect_sdk_state(self, source: Path) -> bool:
        """Preserve all diffs and exact blob/worktree evidence before refusing changes."""
        states, errors = {}, {}
        for label, flags in [('status', ['status', '--porcelain=v1', '-z', '--untracked-files=no']),
                             ('working-diff', ['diff', '--binary']), ('index-diff', ['diff', '--cached', '--binary'])]:
            try:
                states[label] = self.run(f'original-sdk-{label}', ['git', *flags], source)
            except (OSError, RuntimeError) as error:
                errors[label] = str(error)
        evidence = {'source': str(source), 'collectionErrors': errors, 'files': []}
        if 'status' in states:
            # Use the saved raw NUL-delimited status, not run()'s whitespace-stripped return.
            records = (self.output / 'original-sdk-status.log').read_text(encoding='utf-8').split('\0')
            position = 0
            while position < len(records):
                record = records[position]
                position += 1
                if not record:
                    continue
                status, relative = record[:2], record[3:]
                if len(record) < 4 or record[2] != ' ':
                    errors['statusParsing'] = f'Invalid porcelain status record: {record!r}'
                    continue
                paths = [relative]
                if any(flag in status for flag in 'RC'):
                    if position >= len(records) or not records[position]:
                        errors['statusParsing'] = 'Missing rename/copy source path'
                    else:
                        paths.append(records[position])
                        position += 1
                for relative in paths:
                    item = {'path': relative, 'status': status,
                            'absolutePath': str(source / relative), 'pathCharacters': len(str(source / relative))}
                    index = len(evidence['files'])
                    item['expectedHead'] = self.sdk_blob_hash(f'original-sdk-file-{index}-head', source,
                                                             self.receipt['sdkCommit'], relative)
                    item['index'] = self.sdk_blob_hash(f'original-sdk-file-{index}-index', source, '', relative)
                    try:
                        path = source / relative
                        if not within(path, source):
                            raise ValueError('Modified SDK path escaped source root')
                        content = path.read_bytes()
                        item['worktree'] = {'sha256': hashlib.sha256(content).hexdigest(), 'bytes': len(content)}
                    except (OSError, ValueError) as error:
                        item['worktree'] = {'readError': str(error)}
                    evidence['files'].append(item)
        self.receipt['originalSdkState'] = evidence
        (self.output / 'original-sdk-state.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
        self.save()
        return bool(errors or any(states.values()))

    def prepare_sdk(self) -> tuple[Path, Path]:
        temporary = Path(self.env['RUNNER_TEMP']).resolve(strict=True)
        if not within(self.private, temporary) or self.private == temporary:
            raise ValueError('Private root must be a child of RUNNER_TEMP')
        if any(within(self.private, root) or within(root, self.private) for root in [self.app, self.media]):
            raise ValueError('Private toolchain must be separate from source checkouts')
        self.private.mkdir(parents=True, exist_ok=True)
        source = self.args.flutter_root.resolve(strict=True)
        # Linked worktree .git files could make reset in the existing recipe mutate another checkout.
        if not (source / '.git').is_dir() or not within(source / '.git', source):
            raise ValueError('Flutter SDK must use an independent .git directory')
        if Path(self.run('original-sdk-root', ['git', 'rev-parse', '--show-toplevel'], source)).resolve() != source:
            raise ValueError('Flutter git worktree escaped SDK root')
        self.receipt['sdkCommit'] = self.run('original-sdk-head', ['git', 'rev-parse', 'HEAD'], source)
        self.receipt['sdkTree'] = self.run('original-sdk-tree', ['git', 'rev-parse', 'HEAD^{tree}'], source)
        if self.collect_sdk_state(source):
            raise ValueError('Flutter SDK has unknown modifications or unreadable state; preserved and refused before patching')
        sdk = source if within(source, self.private) else self.private / 'f'
        if sdk != source:
            if sdk.exists():
                raise ValueError('Private SDK copy target already exists; refusing to overwrite')
            shutil.copytree(source, sdk, symlinks=True)
            # Only copied, generated compiler caches are removed; checkout files are untouched.
            shutil.rmtree(sdk / 'packages/flutter_tools/.dart_tool', ignore_errors=True)
            for name in ('flutter_tools.snapshot', 'flutter_tools.stamp'):
                (sdk / 'bin/cache' / name).unlink(missing_ok=True)
        cache = self.private / 'p'
        cache.mkdir(exist_ok=True)
        if not within(cache, self.private):
            raise ValueError('Pub cache escaped private root')
        if Path(self.run('private-sdk-root', ['git', 'rev-parse', '--show-toplevel'], sdk)).resolve() != sdk:
            raise ValueError('Private Flutter git worktree escaped SDK root')
        flutter = sdk / 'bin' / ('flutter.bat' if os.name == 'nt' else 'flutter')
        dart = sdk / 'bin/cache/dart-sdk/bin' / ('dart.exe' if os.name == 'nt' else 'dart')
        for executable in (flutter, dart):
            if not executable.is_file() or not within(executable, self.private):
                raise ValueError('Flutter executable escaped private SDK')
        self.env.update(FLUTTER_ROOT=str(sdk), PUB_CACHE=str(cache), GITHUB_WORKSPACE=str(self.app))
        self.env['PATH'] = os.pathsep.join([str(sdk / 'bin'), str(dart.parent), self.env.get('PATH', '')])
        self.run('flutter-tools-resolve', [str(dart), 'pub', 'get'], sdk / 'packages/flutter_tools')
        roots = package_roots(sdk / 'packages/flutter_tools/.dart_tool/package_config.json', [sdk, cache])
        self.receipt.update(flutterRoot=str(sdk), pubCache=str(cache), flutterToolsPackages=roots)
        self.run('toolchain', [str(flutter), '--version'], self.app)
        machine = json.loads(self.run('toolchain-machine', [str(flutter), '--version', '--machine'], self.app))
        contract = re.findall(r'^  flutter: ([0-9]+\.[0-9]+\.[0-9]+)\s*$',
                              (self.app / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
        if len(contract) != 1 or machine.get('frameworkVersion') != contract[0]:
            raise ValueError('Flutter toolchain does not match exact App pubspec contract')
        self.receipt['toolchain'] = machine
        return flutter, cache

    def resolution(self, label: str, sdk: Path, cache: Path) -> dict:
        config = self.app / '.dart_tool/package_config.json'
        receipt = {'packages': verify(config, self.media),
                   'roots': package_roots(config, [self.app, self.media, sdk, cache])}
        (self.output / f'{label}.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
        return receipt

    def prepare(self) -> None:
        self.receipt['vector'] = self.vector('before')
        self.check_sources()
        self.check_patch_inputs()
        before_hashes = self.source_hashes()
        flutter, cache = self.prepare_sdk()
        sdk = Path(self.env['FLUTTER_ROOT'])
        self.run('resolve', [str(flutter), 'pub', 'get'], self.app)
        before = self.resolution('source-resolution-before', sdk, cache)
        patch = str(self.app / 'lib/scripts/patch.ps1')
        for mode in ('SdkOnly', 'PackagesOnly'):
            self.run(f'patch-{mode}', ['pwsh', '-NoLogo', '-NoProfile', '-File', patch,
                                      self.args.platform, f'-{mode}'], self.app)
        self.run('patched-sdk-status', ['git', 'status', '--porcelain', '--untracked-files=no'], sdk)
        self.run('patched-sdk-diff', ['git', 'diff', '--binary'], sdk)
        patched = self.resolution('source-resolution-patched', sdk, cache)
        if before != patched:
            raise ValueError('Package resolution changed during patches')
        package_roots(sdk / 'packages/flutter_tools/.dart_tool/package_config.json', [sdk, cache])
        self.check_sources()
        if before_hashes != self.source_hashes():
            raise ValueError('Bootstrap modified application/library source files')
        self.receipt['afterVector'] = self.vector('after')
        if self.receipt['afterVector'] != self.receipt['vector']:
            raise ValueError('Source vector changed during bootstrap')
        self.receipt['sourceHashes'] = before_hashes
        self.receipt['status'] = 'prepared-source-only'
        self.save()
        for variable, value in [('FLUTTER_ROOT', str(sdk)), ('PUB_CACHE', str(cache)),
                                ('ROUTING_APP_ROOT', str(self.app))]:
            if '\n' in value or '\r' in value:
                raise ValueError('Invalid environment path')
            if self.env.get('GITHUB_ENV'):
                with Path(self.env['GITHUB_ENV']).open('a', encoding='utf-8') as stream:
                    stream.write(f'{variable}={value}\n')
        if self.env.get('GITHUB_PATH'):
            with Path(self.env['GITHUB_PATH']).open('a', encoding='utf-8') as stream:
                stream.write(str(sdk / 'bin') + '\n' + str(sdk / 'bin/cache/dart-sdk/bin') + '\n')

    def finalize(self) -> None:
        previous = json.loads((self.output / 'bootstrap.json').read_text(encoding='utf-8'))
        if previous['status'] != 'prepared-source-only':
            raise ValueError('Bootstrap is not prepared')
        self.receipt = previous
        self.receipt['finalVector'] = self.vector('final')
        if self.receipt['finalVector'] != previous['vector']:
            raise ValueError('Final source vector differs from prepared vector')
        sdk, cache = Path(previous['flutterRoot']), Path(previous['pubCache'])
        self.check_sources()
        after = self.resolution('source-resolution-after', sdk, cache)
        before = json.loads((self.output / 'source-resolution-before.json').read_text(encoding='utf-8'))
        if after != before or previous['sourceHashes'] != self.source_hashes():
            raise ValueError('Sources or package resolution changed after bootstrap')
        self.receipt['status'] = 'fresh-source-only'
        self.save()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-root', type=Path, required=True)
    parser.add_argument('--media-kit-root', type=Path, required=True)
    parser.add_argument('--flutter-root', type=Path, required=True)
    parser.add_argument('--private-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expected-app-sha', required=True)
    parser.add_argument('--expected-media-kit-sha', required=True)
    parser.add_argument('--platform', choices=['android', 'linux', 'macos', 'windows'], required=True)
    parser.add_argument('--finalize', action='store_true')
    args = parser.parse_args()
    bootstrap = Bootstrap(args)
    try:
        bootstrap.finalize() if args.finalize else bootstrap.prepare()
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        bootstrap.receipt.update(status='failed', error=str(error))
        bootstrap.save()
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
