#!/usr/bin/env python3
"""Acquire only the explicitly selected, CORE-reviewed two-artifact native input."""
from __future__ import annotations
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import stat
import subprocess
import threading
import zipfile

from verify_routing_native_inputs import (ACCEPTED, GateError, TASK, file_digest,
    read_json, relative, selected_entry, validate_manifest, verify)

MAX_ZIP = 1024 * 1024 * 1024


def timestamp(value):
    if not isinstance(value, str) or not value.endswith('Z'):
        raise GateError('missing API UTC timestamp')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


class GitHub:
    def __init__(self, receipt):
        self.receipt = receipt

    def request(self, endpoint, destination, limit=MAX_ZIP):
        command = ['gh', 'api', '--method', 'GET', endpoint]
        step = {'argv': command, 'exitCode': None}
        self.receipt['commands'].append(step)
        errors, stderr_chunks = [], []
        # Drain pipes concurrently, enforcing limits during transfer rather than
        # after a malicious/oversized response has filled the private volume.
        with destination.open('xb') as stream:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            def drain(pipe, sink, maximum, diagnostic=False):
                total = 0
                try:
                    while chunk := pipe.read(65536):
                        total += len(chunk)
                        if total > maximum:
                            raise GateError('GitHub response exceeds streaming limit')
                        if diagnostic:
                            stderr_chunks.append(chunk)
                        else:
                            sink.write(chunk)
                except Exception as error:
                    errors.append(error)
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                finally:
                    pipe.close()
            workers = [threading.Thread(target=drain, args=(process.stdout,stream,limit)),
                       threading.Thread(target=drain, args=(process.stderr,None,256*1024,True))]
            for worker in workers:
                worker.start()
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired as error:
                errors.append(error)
                process.kill()
                process.wait()
            for worker in workers:
                worker.join()
        step.update(exitCode=process.returncode, stderr=b''.join(stderr_chunks).decode('utf-8',errors='replace'))
        if errors:
            step['error'] = str(errors[0])
            raise GateError(f'GitHub acquisition failed: {endpoint}: {errors[0]}')
        if process.returncode or step['stderr'].strip():
            raise GateError(f'GitHub acquisition failed: {endpoint}: exit {process.returncode}')
        return destination

    def metadata(self, endpoint, root, label):
        path = self.request(endpoint, root / f'{label}.json', limit=4*1024*1024)
        value, _ = read_json(path)
        return value


def validate_metadata(spec, metadata, jobs):
    if metadata.get('id') != spec['artifactId'] or metadata.get('name') != spec['name'] or metadata.get('expired') is not False:
        raise GateError('artifact ID/name/expiry mismatch')
    if metadata.get('digest') != 'sha256:' + spec['zipSha256']:
        raise GateError('artifact API ZIP digest mismatch/missing')
    if type(metadata.get('size_in_bytes')) is not int or not 0 < metadata['size_in_bytes'] <= MAX_ZIP:
        raise GateError('artifact API size invalid')
    run = metadata.get('workflow_run', {})
    if run.get('id') != spec['runId'] or run.get('head_sha') != spec['producerHeadSha']:
        raise GateError('artifact producer run/HEAD mismatch')
    matches = [j for j in jobs if j.get('id') == spec['uploadJobId']]
    if len(matches) != 1:
        raise GateError('approved upload job missing/ambiguous in exact attempt')
    job = matches[0]
    if job.get('run_id') != spec['runId'] or job.get('run_attempt') != spec['attempt'] or job.get('head_sha') != spec['producerHeadSha'] or job.get('conclusion') != 'success' or job.get('status') != 'completed':
        raise GateError('upload job attempt/run/HEAD/success mismatch')
    if not timestamp(job.get('started_at')) <= timestamp(metadata.get('created_at')) <= timestamp(job.get('completed_at')):
        raise GateError('artifact creation outside approved upload-job time window')


def safe_unpack(archive_path, destination):
    """Extract only into a fresh private directory, validating every ZIP entry."""
    destination.mkdir(mode=0o700)
    names, total = set(), 0
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        if len(entries) > 100000:
            raise GateError('artifact ZIP too many entries')
        for item in entries:
            name = item.filename
            if item.orig_filename != name or (item.is_dir() and item.file_size):
                raise GateError('invalid ZIP name/directory')
            relative(name.rstrip('/') if item.is_dir() else name, 'artifact ZIP member')
            if name in names or stat.S_ISLNK(item.external_attr >> 16) or item.flag_bits & 1:
                raise GateError('duplicate/symlink/encrypted artifact ZIP member')
            names.add(name)
            total += item.file_size
            if total > MAX_ZIP or item.file_size > 256 * 1024 * 1024 or (item.file_size > 1024 * 1024 and item.file_size > max(1, item.compress_size) * 250):
                raise GateError('artifact ZIP expansion limit')
            target = destination / name
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(item) as source, target.open('xb') as sink:
                size = 0
                while chunk := source.read(1024 * 1024):
                    size += len(chunk)
                    if size > item.file_size or size > 256 * 1024 * 1024:
                        raise GateError('artifact ZIP actual expansion limit')
                    sink.write(chunk)
                if size != item.file_size:
                    raise GateError('artifact ZIP size mismatch')
    return {n for n in names if not n.endswith('/')}


def staging_apk(root, flavor, consumer, selected):
    expected = {f'PiliPlusX_routing_{flavor}_arm64-v8a.apk', 'native-after.json', 'variant.json', 'bootstrap.json', 'apk-signature.log', 'source.txt'}
    if root.is_symlink() or {p.name for p in root.iterdir()} != expected or any(not p.is_file() or p.is_symlink() for p in root.iterdir()):
        raise GateError('staging artifact layout mismatch')
    native, _ = read_json(root/'native-after.json')
    variant, _ = read_json(root/'variant.json')
    bootstrap, _ = read_json(root/'bootstrap.json')
    if native.get('status') != 'passed' or native.get('nativeVerified') is not True or native.get('consumer') != consumer or native.get('native', {}).get('manifestSha256') != selected:
        raise GateError('staging native consumer/selection/status mismatch')
    if variant.get('status') != 'finalized' or variant.get('flavor') != flavor or variant.get('appCommit') != consumer['appCommit'] or variant.get('mediaKitCommit') != consumer['mediaKitCommit']:
        raise GateError('staging variant identity/finalization mismatch')
    vector = bootstrap.get('finalVector', {})
    if bootstrap.get('status') != 'fresh-source-only' or vector.get('app') != consumer['appCommit'] or vector.get('media-kit') != consumer['mediaKitCommit']:
        raise GateError('staging bootstrap vector/freshness mismatch')
    expected_source = f"pending-parity=true\napp={consumer['appCommit']}\nmedia-kit={consumer['mediaKitCommit']}\ndeviceVerified=false\n"
    if (root/'source.txt').read_text() != expected_source:
        raise GateError('staging source vector mismatch')
    return root/f'PiliPlusX_routing_{flavor}_arm64-v8a.apk'


def acquire(output, accepted, consumer, receipt, *, github=None, readelf='readelf', nm='nm', staging=None, flavor=None):
    receipt.update(task=TASK, scope='routing-native-acquisition', stage='selection',
                   status='failed', nativeVerified=False, deviceVerified=False,
                   consumer=consumer, commands=[])
    entry = selected_entry(accepted)  # Empty selection fails before any API/download.
    receipt['selectedManifestSha256'] = entry['manifestSha256']
    apk = None
    if staging is not None:
        if flavor not in ('android','pink'):
            raise GateError('staging requires explicit Android/Pink flavor')
        apk = staging_apk(staging, flavor, consumer, entry['manifestSha256'])
    temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    output = output.absolute()
    if output.exists() or not output.resolve().is_relative_to(temporary) or output.resolve() == temporary:
        raise GateError('acquisition output must be a fresh child of RUNNER_TEMP')
    # Never traverse a pre-existing symlink while creating the private stage.
    for parent in output.parents:
        if parent.resolve() == temporary:
            break
        if parent.is_symlink():
            raise GateError('acquisition staging path contains symbolic link')
    output.mkdir(parents=True, mode=0o700)
    github = github or GitHub(receipt)
    unpacked = {}
    for label in ('jar', 'evidence'):
        receipt['stage'] = f'acquire-{label}'
        spec = entry['acquisition'][label]
        base = f"repos/{spec['repository']}/actions"
        metadata = github.metadata(f"{base}/artifacts/{spec['artifactId']}", output, f'{label}-metadata')
        jobs = []
        page = 1
        while True:
            response = github.metadata(f"{base}/runs/{spec['runId']}/attempts/{spec['attempt']}/jobs?per_page=100&page={page}", output, f'{label}-jobs-{page}')
            batch = response.get('jobs')
            if not isinstance(batch, list) or type(response.get('total_count')) is not int:
                raise GateError('invalid attempt jobs API response')
            jobs.extend(batch)
            if len(jobs) >= response['total_count']:
                break
            if not batch or page >= 100:
                raise GateError('incomplete/bounded attempt jobs pagination')
            page += 1
        validate_metadata(spec, metadata, jobs)
        archive = github.request(f"{base}/artifacts/{spec['artifactId']}/zip", output / f'{label}.zip')
        if archive.stat().st_size != metadata['size_in_bytes'] or file_digest(archive) != spec['zipSha256']:
            raise GateError('downloaded ZIP size/hash differs from approved artifact')
        try:
            unpacked[label] = safe_unpack(archive, output / label)
        except Exception as error:
            raise GateError(f'{label} ZIP extraction failed: {error}') from error
    receipt['stage'] = 'manifest-layout'
    manifest_path = output / 'evidence/manifest.json'
    manifest, raw = read_json(manifest_path)
    validate_manifest(manifest)
    expected = {'manifest.json'} | {'evidence/' + e['path'] for e in manifest['evidence']}
    if unpacked['evidence'] != expected or unpacked['jar'] != {manifest['artifact']['name']}:
        raise GateError('A/B artifact file layout differs from approved manifest closure')
    native = {}
    receipt['stage'] = 'native-input-gate'
    try:
        verify(output / 'jar' / manifest['artifact']['name'], manifest_path,
               output / 'evidence/evidence', accepted, consumer, native,
               readelf=readelf, nm=nm, apk=apk)
    finally:
        receipt['nativeGate'] = native
    receipt.update(status='passed', stage='complete', nativeVerified=True,
                   jar=str(output / 'jar' / manifest['artifact']['name']),
                   manifest=str(manifest_path), evidenceRoot=str(output / 'evidence/evidence'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('output', 'receipt'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--app-commit', required=True)
    parser.add_argument('--media-kit-commit', required=True)
    parser.add_argument('--readelf', default='readelf')
    parser.add_argument('--nm', default='nm')
    parser.add_argument('--staging', type=Path)
    parser.add_argument('--flavor', choices=('android','pink'))
    args = parser.parse_args()
    receipt = {'task': TASK, 'stage': 'trusted-ledger', 'status': 'failed', 'nativeVerified': False, 'deviceVerified': False, 'commands': []}
    code = 0
    try:
        ledger, _ = read_json(ACCEPTED)
        acquire(args.output, ledger, {'appCommit': args.app_commit, 'mediaKitCommit': args.media_kit_commit}, receipt, readelf=args.readelf, nm=args.nm, staging=args.staging, flavor=args.flavor)
    except Exception as error:
        receipt.update(status='failed', nativeVerified=False, reason=str(error))
        code = 1
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    if code == 0 and os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as stream:
            for key in ('jar', 'manifest', 'evidenceRoot'):
                stream.write(f'{key}={receipt[key]}\n')
    print(f"routing native acquisition: {receipt['status']} ({receipt['stage']})")
    return code


if __name__ == '__main__':
    raise SystemExit(main())
