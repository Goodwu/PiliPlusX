#!/usr/bin/env python3
"""Ensure every release workflow uses the same immutable media-kit commit."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SHA_RE = r"[0-9a-f]{40}"
LOCK_RE = re.compile(
    rf"verify_media_kit_lock\.py\s+pubspec\.lock\s+--commit\s+({SHA_RE})"
)
MANIFEST_RE = re.compile(rf"--media-kit-commit\s+({SHA_RE})")


def routing_block(text):
    if text.count('# BEGIN ROUTING ANDROID') != 1 or text.count('# END ROUTING ANDROID') != 1:
        raise ValueError('exact routing workflow block required')
    return text.split('# BEGIN ROUTING ANDROID',1)[1].split('# END ROUTING ANDROID',1)[0]


def routing_step(block, name):
    match=re.search(r'^            - name: '+re.escape(name)+r'\n(.*?)(?=^            - name:|\Z)',block,re.M|re.S)
    if not match:
        raise ValueError('missing routing gate: '+name)
    return match.group(1)


def verify_routing_workflows(directory):
    texts={name:(directory/name).read_text() for name in ('build.yml','pink.yml','routing-source-integration.yml')}
    build=texts['build.yml'];source=texts['routing-source-integration.yml']
    vector=build.split('    routing-vector:',1)[1].split('    hdr_unit_tests:',1)[0]
    if vector.count('library_head=$(git ls-remote --exit-code https://github.com/Goodwu/media-kit.git refs/heads/routing/MK-ROUTING-20261011 | cut -f1)') != 1:
        raise ValueError('Build must capture one library vector')
    for token in ('test "$app_head" = "$APP_SHA"', 'needs: routing-vector', 'app-sha: ${{ needs.routing-vector.outputs.app-sha }}', 'media-kit-sha: ${{ needs.routing-vector.outputs.media-kit-sha }}'):
        if token not in build:
            raise ValueError('missing captured vector contract: '+token)
    for token in ('SUPPLIED_MEDIA_SHA: ${{ inputs.media-kit-sha }}', 'library_head="$SUPPLIED_MEDIA_SHA"', 'inputs.app-sha || github.event.pull_request.head.sha || github.sha'):
        if token not in source:
            raise ValueError('source callee must consume caller vector: '+token)
    for name,flavor,mode in (('build.yml','android',"needs.routing-vector.outputs.routing-mode == 'true'"),('pink.yml','pink','inputs.routing-mode')):
        block=routing_block(texts[name])
        gates=[
            ('Bootstrap actual routing Android patches', ('uses: ./app/.github/actions/routing-bootstrap','platform: android')),
            ('Acquire explicitly accepted native input before Gradle', ('scripts/acquire_routing_native_inputs.py','--output','--receipt','--app-commit','--media-kit-commit','--readelf','--nm')),
            (f'Prepare immutable routing {flavor} variant', ('scripts/prepare_android_variant.py','--manifest-parser',f'--flavor {flavor}','--bootstrap','--media-kit-root','--app-commit','--media-kit-commit','scripts/verify_media_kit_lock.py','--mode routing','--variant-receipt','scripts/verify_workflow_media_kit_refs.py')),
            ('Build routing Release APK with verified local arm64 input', ('scripts/prepare_android_variant.py','--manifest-parser','--check-prebuild','flutter build apk --release --split-per-abi --target-platform android-arm64','--android-project-arg=mediaKitLocalArm64Jar="$VERIFIED_JAR"','--android-project-arg=mediaKitArm64Only=true','--no-pub')),
            ('Verify routing APK native members ABI and signature', ('scripts/verify_routing_native_inputs.py','--apk "$apk"','--jar "$VERIFIED_JAR"','--manifest "$VERIFIED_MANIFEST"','--evidence-root "$VERIFIED_EVIDENCE"','--receipt "$ROUTING_RESULTS/native-after.json"','scripts/verify_artifact.py','--abi arm64-v8a','"$apksigner" verify --verbose')),
            ('Finalize routing variant after build', ('scripts/prepare_android_variant.py','--manifest-parser','--finalize',"steps.routing_variant.outcome == 'success'")),
            ('Finalize original routing sources and freshness', ('scripts/prepare_routing_ci.py','--finalize','--expected-app-sha','--expected-media-kit-sha',"steps.routing_prepare.outcome == 'success'")),
            ('Stage verified routing APK pending cross-variant parity', ('pending-parity=true','deviceVerified=false','success()')),
            ('Upload routing staging evidence only', ('id: routing_staging',f'name: routing-{flavor}-staging','success()','if-no-files-found: error')),
            ('Upload routing native failure diagnostics', ('always()',f'name: routing-{flavor}-diagnostics-', 'path: ${{ env.ROUTING_RESULTS }}')),
        ]
        positions=[]
        for label,tokens in gates:
            step=routing_step(block,label)
            positions.append(block.index('- name: '+label))
            if mode not in step or 'if:' not in step:
                raise ValueError('routing mode guard missing: '+label)
            for token in tokens:
                if token not in step:
                    raise ValueError('routing gate contract missing: '+label+': '+token)
            if 'run: |' in step and 'set -euo pipefail' not in step:
                raise ValueError('routing shell must propagate failed commands: '+label)
            if label.startswith('Build routing') and step.index('--check-prebuild') > step.index('flutter build apk'):
                raise ValueError('prebuild source gate must run before Gradle')
            if label.startswith(('Build routing','Verify routing','Prepare immutable','Acquire explicitly')) and 'always()' in step:
                raise ValueError('failed prerequisites cannot reach build/candidate gates')
        if positions != sorted(positions):
            raise ValueError('routing gates out of order')
        if 'softprops/action-gh-release' in block:
            raise ValueError('routing must never publish Release')
    parity=build.split('    verify_android_native_parity:',1)[1].split('    ios:',1)[0]
    for token in ('needs: [android, pink, routing-vector]', 'needs.android.outputs.staging-id', 'needs.pink.outputs.staging-id', 'scripts/verify_android_native_parity.py', 'scripts/acquire_routing_native_inputs.py', '--staging', '--flavor', 'scripts/verify_artifact.py', '"$apksigner" verify --verbose', 'Verify routing freshness before candidate upload', '"$APP_SHA"', '"$MEDIA_SHA"'):
        if token not in parity:
            raise ValueError('final parity/current-source contract missing: '+token)
    for flavor in ('Android','Pink'):
        label=f'Upload routing {flavor} candidate after parity'
        step=routing_step(parity,label)
        if "if: ${{ success() && needs.routing-vector.outputs.routing-mode == 'true' }}" not in step or 'name: routing-'+flavor.lower()+'-candidate-' not in step:
            raise ValueError('candidate upload requires all gates and routing-only artifact identity')
    for token in ('Initialize parity failure diagnostics', 'parity-diagnostics/source.txt', 'set -euo pipefail', 'tee "$RUNNER_TEMP/parity-diagnostics/parity.log"', 'parity-diagnostics/freshness.txt'):
        if token not in parity:
            raise ValueError('parity failure evidence contract missing: '+token)
    diagnostics=routing_step(parity,'Upload routing parity diagnostics')
    if 'always()' not in diagnostics or 'if-no-files-found: error' not in diagnostics:
        raise ValueError('parity failures must preserve diagnostic evidence')
    if 'run-id:' in parity or 'continue-on-error' in parity or 'continue-on-error' in routing_block(build) or 'continue-on-error' in routing_block(texts['pink.yml']):
        raise ValueError('no external-run staging or discarded gate failures')
    if "github.ref_name != 'routing/MK-ROUTING-20261011'" not in texts['pink.yml']:
        raise ValueError('Pink routing branch cannot publish by production fallback')
    dispatch=routing_step(texts['pink.yml'],'Reject uncaptured routing dispatch')
    if "github.ref_name == 'routing/MK-ROUTING-20261011' && !inputs.routing-mode" not in dispatch or 'exit 1' not in dispatch:
        raise ValueError('uncaptured routing dispatch must fail before production native download')
    if 'contents: write' not in texts['pink.yml']:
        raise ValueError('production Pink publishing permission must remain available')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", required=True)
    parser.add_argument("--mode", choices=("production","routing"), default="production")
    parser.add_argument(
        "--workflow-dir", type=Path, default=Path(".github/workflows")
    )
    args = parser.parse_args()

    if not re.fullmatch(SHA_RE, args.commit):
        parser.error("--commit must be a full 40-character lowercase SHA")
    if args.mode == 'routing':
        verify_routing_workflows(args.workflow_dir)
        print('routing workflow media-kit references verified: captured vector and native/variant gates')
        return
    workflows = sorted(args.workflow_dir.glob("*.yml"))
    if not workflows:
        raise SystemExit(f"no workflow files found in {args.workflow_dir}")

    failures: list[str] = []
    lock_count = 0
    manifest_count = 0
    for workflow in workflows:
        text = workflow.read_text(encoding="utf-8")
        if workflow.name == 'routing-source-integration.yml':
            # This explicitly validated source-only workflow has no production
            # dependency/native pin; never silently classify an unknown workflow.
            verify_routing_workflows(args.workflow_dir)
            continue
        # Orchestrators only call reusable build workflows and therefore do
        # not resolve Dart packages themselves.
        if not re.search(r"(?:flutter pub get|flutter build|fastforge package)", text):
            continue
        lock_refs = LOCK_RE.findall(text)
        manifest_refs = MANIFEST_RE.findall(text)
        lock_count += len(lock_refs)
        manifest_count += len(manifest_refs)
        if not lock_refs:
            failures.append(f"{workflow}: no immutable lock verification reference")
        if any(ref != args.commit for ref in lock_refs):
            failures.append(f"{workflow}: lock verification references {lock_refs}")
        if any(ref != args.commit for ref in manifest_refs):
            failures.append(f"{workflow}: manifest references {manifest_refs}")

    if failures:
        raise SystemExit("workflow media-kit reference verification failed:\n" + "\n".join(failures))
    print(
        f"workflow media-kit references verified: {lock_count} lock checks, "
        f"{manifest_count} manifest references at {args.commit}"
    )


if __name__ == "__main__":
    main()
