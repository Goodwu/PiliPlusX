"""Source routing and release-caller workflow contracts.

These checks cover this repository's concrete job/step layouts, not arbitrary
YAML. Actual GitHub workflow execution remains a separate integration gate.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def validate_apple_calls(text):
    for job in ('ios', 'mac'):
        block = re.search(r'^    ' + job + r':\n(.*?)(?=^    [a-z_]+:|\Z)', text, re.M | re.S)
        if not block:
            raise ValueError('Missing job ' + job)
        body = block.group(1)
        if 'uses: ./.github/workflows/' + job + '.yml' not in body:
            raise ValueError('Unexpected callee ' + job)
        if not re.search(r'^        with:\n(?:            .*\n)*?            ref: \$\{\{ github.event.pull_request.head.sha \|\| github.sha \}\}$', body, re.M):
            raise ValueError('Missing exact current source ref in ' + job)


def routing_job(text, name):
    block = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [a-z][a-z-]*:|\Z)',
                      text, re.M | re.S)
    if not block:
        raise ValueError('Missing routing job ' + name)
    return block.group(1)


def validate_routing_bootstrap(text):
    """Require exact sources and real platform preparation through finalization."""
    vector = routing_job(text, 'source-vector')
    if text.count('https://github.com/Goodwu/media-kit.git refs/heads/routing/MK-ROUTING-20261011') != 1:
        raise ValueError('media-kit HEAD must be captured once')
    if 'test "$app_head" = "$EXPECTED_APP_SHA"' not in vector:
        raise ValueError('Missing current App vector check')
    if '[[ "$library_head" =~ ^[0-9a-f]{40}$ ]]' not in vector:
        raise ValueError('Missing exact library vector check')
    if 'media-kit-sha: ${{ steps.vector.outputs.media-kit-sha }}' not in vector:
        raise ValueError('Missing library vector output')
    if 'PILIPLUSX_SKIP' in text:
        raise ValueError('Routing source jobs must execute the actual patch chain')
    if 'ci-routing-results' in text or 'path: app/' in text:
        raise ValueError('Source receipts must stay outside clean App inputs')
    for name in ('app-source', 'platform-source'):
        body = routing_job(text, name)
        if 'needs: source-vector' not in body:
            raise ValueError(name + ' must consume the captured vector')
        checkout = body.find('- uses: actions/checkout@v4')
        for setting in ('git config --global core.autocrlf false', 'git config --global core.eol lf'):
            position = body.find(setting)
            if position < 0 or position >= checkout:
                raise ValueError(name + ' requires LF configuration before checkout')
        longpaths = body.find('git config --global core.longpaths true')
        if longpaths < 0 or longpaths >= checkout:
            raise ValueError(name + ' requires long-path support before checkout')
        if 'ref: ${{ github.event.pull_request.head.sha || github.sha }}' not in body:
            raise ValueError(name + ' requires exact App event HEAD')
        library = body.split('repository: Goodwu/media-kit', 1)[-1].split('persist-credentials: false', 1)[0]
        if 'ref: ${{ needs.source-vector.outputs.media-kit-sha }}' not in library:
            raise ValueError(name + ' requires captured exact library checkout')
        if 'uses: ./app/.github/actions/routing-bootstrap' not in body:
            raise ValueError(name + ' must execute the shared bootstrap action')
        for value in ('app-sha: ${{ env.EXPECTED_APP_SHA }}',
                      'media-kit-sha: ${{ env.EXPECTED_MEDIA_KIT_SHA }}'):
            if value not in body:
                raise ValueError(name + ' must supply exact bootstrap inputs')
        if 'scripts/prepare_routing_ci.py' not in body or '--finalize' not in body:
            raise ValueError(name + ' requires post-test source finalization')
        for argument in ('--expected-app-sha', '--expected-media-kit-sha', '--private-root', '--output'):
            if argument not in body:
                raise ValueError(name + ' finalization misses ' + argument)
        for command in ('flutter analyze --no-pub', 'flutter test --no-pub --concurrency=1',
                        'flutter build bundle --debug --no-pub', 'kernel_blob.bin'):
            if command not in body:
                raise ValueError(name + ' misses source validation ' + command)
        for step in re.split(r'^      - ', body, flags=re.M):
            if 'run: |' in step and any(command in step for command in (
                    'flutter --version', 'flutter analyze', 'flutter test',
                    'flutter build', 'scripts/prepare_routing_ci.py')):
                if "if: ${{ !cancelled() && steps.prepare.outcome == 'success' }}" not in step:
                    raise ValueError(name + ' may validate or finalize unprepared inputs')
        artifacts = body.split('- uses: actions/upload-artifact@v4', 1)
        if len(artifacts) != 2 or 'if: always()' not in artifacts[1]:
            raise ValueError(name + ' must archive failure evidence unconditionally')
        if 'git merge-base --is-ancestor FETCH_HEAD HEAD' not in body:
            raise ValueError(name + ' misses the App base gate')
        if 'RUNNER_TEMP' not in body or 'path: ${{ env.ROUTING_RESULTS }}' not in body:
            raise ValueError(name + ' must archive private receipts')
        if 'if-no-files-found: error' not in body:
            raise ValueError(name + ' must preserve failure evidence')
    android = routing_job(text, 'app-source')
    if 'platform: android' not in android or '--platform android --finalize' not in android:
        raise ValueError('Primary source job must execute Android patches')
    for command in ('flutter test --no-pub --platform chrome',
                    'flutter build web --target lib/main_web.dart --no-pub',
                    'test -s build/web/main.dart.js', 'web-sha256.txt', 'set -euo pipefail'):
        if command not in android:
            raise ValueError('Primary source job misses ' + command)
    matrix = routing_job(text, 'platform-source')
    if 'fail-fast: false' not in matrix:
        raise ValueError('Every real platform must finish independently')
    for os_name, platform in (('ubuntu-latest', 'linux'), ('macos-latest', 'macos'),
                              ('windows-latest', 'windows')):
        if f'- os: {os_name}\n            platform: {platform}' not in matrix:
            raise ValueError('Missing real bootstrap runner for ' + platform)
    if 'platform: ${{ matrix.platform }}' not in matrix:
        raise ValueError('Matrix must execute its actual platform patch')
    if "--platform '${{ matrix.platform }}' --finalize" not in matrix:
        raise ValueError('Matrix must finalize its actual platform')
    if 'shell: pwsh' not in matrix:
        raise ValueError('Matrix requires a cross-platform shell')
    for failure in ('Strict App analysis failed', 'Flutter App tests failed',
                    'Dart/assets bundle compilation failed',
                    'Final source freshness/package binding verification failed'):
        if f"if ($LASTEXITCODE -ne 0) {{ throw '{failure}' }}" not in matrix:
            raise ValueError('Matrix must propagate native command failure: ' + failure)


def validate_short_bootstrap_paths(action, workflow):
    required = {
        'cache-path': '${{ runner.temp }}/rb/s',
        'pub-cache-path': '${{ runner.temp }}/rb/p',
        'PRIVATE_ROOT': '${{ runner.temp }}/rb',
    }
    for name, expected in required.items():
        match = re.search(r'^\s+' + re.escape(name) + r': (.+)$', action, re.M)
        if not match or match.group(1) != expected:
            raise ValueError('Bootstrap requires one short private installation root: ' + name)
    if "Join-Path $env:PRIVATE_ROOT 'r'" not in action:
        raise ValueError('Action results must use the short private root')
    sdk_setup = action.find('uses: subosito/flutter-action@v2')
    for setting in ('core.longpaths true', 'core.autocrlf false', 'core.eol lf'):
        position = action.find('git config --global ' + setting)
        if position < 0 or position >= sdk_setup:
            raise ValueError('SDK requires Git configuration before setup: ' + setting)
    for name, prefix in [('app-source', '$RUNNER_TEMP'), ('platform-source', '$env:RUNNER_TEMP')]:
        body = routing_job(workflow, name)
        if prefix + '/rb/r' not in body or 'routing-bootstrap-' in body:
            raise ValueError('Workflow results disagree with action private root: ' + name)


class ReusableSourceContractTests(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / '.github/workflows/build.yml').read_text()

    def test_current_callers_supply_exact_source_ref(self):
        validate_apple_calls(self.text)

    def test_removing_required_ios_ref_is_detected(self):
        broken = self.text.replace('            ref: ${{ github.event.pull_request.head.sha || github.sha }}\n', '', 1)
        with self.assertRaisesRegex(ValueError, 'ios'):
            validate_apple_calls(broken)

    def test_removing_required_mac_ref_is_detected(self):
        prefix, suffix = self.text.split('    mac:\n', 1)
        suffix = suffix.replace('            ref: ${{ github.event.pull_request.head.sha || github.sha }}\n', '', 1)
        with self.assertRaisesRegex(ValueError, 'mac'):
            validate_apple_calls(prefix + '    mac:\n' + suffix)

    def test_build_uses_the_current_source_validation_pipeline(self):
        text = (ROOT / '.github/workflows/build.yml').read_text()
        block = text.split('    hdr_unit_tests:\n', 1)[1].split('    android:\n', 1)[0]
        self.assertIn('uses: ./.github/workflows/routing-source-integration.yml', block)
        self.assertNotIn('73536ef', block)
        source = (ROOT / '.github/workflows/routing-source-integration.yml').read_text()
        self.assertIn('  workflow_call:', source)
        self.assertIn('path: app', source)
        self.assertIn('path: media-kit', source)
        self.assertIn('uses: ./app/.github/actions/routing-bootstrap', source)
        self.assertIn('verify_hdr_channel.py', source)
        self.assertIn('flutter test --no-pub', source)
        self.assertIn('flutter analyze --no-pub', source)
        self.assertIn('--finalize', source)
        validate_routing_bootstrap(source)
        self.assertIn('group: routing-source-checks-${{ github.workflow }}-', source)

    def test_callees_keep_required_ref_and_release_guards(self):
        for name in ('ios', 'mac'):
            text = (ROOT / f'.github/workflows/{name}.yml').read_text()
            self.assertRegex(text, r'(?s)      ref:\n.*?        required: true\n')
        mac = (ROOT / '.github/workflows/mac.yml').read_text()
        self.assertIn('run_macos_shared_release.py --preflight', mac)


class RoutingBootstrapWiringTests(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / '.github/workflows/routing-source-integration.yml').read_text()

    def test_exact_shared_vector_real_matrix_and_existing_source_gates(self):
        validate_routing_bootstrap(self.text)

    def reject(self, before, after, reason):
        self.assertIn(before, self.text)
        with self.assertRaisesRegex(ValueError, reason):
            validate_routing_bootstrap(self.text.replace(before, after, 1))

    def test_library_branch_checkout_cannot_replace_exact_capture(self):
        self.reject('          ref: ${{ needs.source-vector.outputs.media-kit-sha }}',
                    '          ref: routing/MK-ROUTING-20261011', 'exact library checkout')

    def test_app_pr_merge_commit_cannot_replace_actual_event_head(self):
        body = routing_job(self.text, 'app-source')
        broken = body.replace('ref: ${{ github.event.pull_request.head.sha || github.sha }}',
                              'ref: ${{ github.sha }}')
        with self.assertRaisesRegex(ValueError, 'exact App event HEAD'):
            validate_routing_bootstrap(self.text.replace(body, broken))

    def test_windows_line_endings_must_be_configured_before_checkout(self):
        body = routing_job(self.text, 'platform-source')
        broken = body.replace('          git config --global core.autocrlf false\n', '')
        with self.assertRaisesRegex(ValueError, 'LF configuration before checkout'):
            validate_routing_bootstrap(self.text.replace(body, broken))

    def test_windows_long_paths_must_be_enabled_before_checkout(self):
        body = routing_job(self.text, 'platform-source')
        setting = '          git config --global core.longpaths true\n'
        self.assertIn(setting, body)
        broken = body.replace(setting, '')
        with self.assertRaisesRegex(ValueError, 'long-path support before checkout'):
            validate_routing_bootstrap(self.text.replace(body, broken))
        moved = body.replace(setting, '').replace('      - uses: actions/checkout@v4\n',
                                                     '      - uses: actions/checkout@v4\n' + setting, 1)
        with self.assertRaisesRegex(ValueError, 'long-path support before checkout'):
            validate_routing_bootstrap(self.text.replace(body, moved))

    def test_short_action_paths_and_artifacts_are_consistent(self):
        action = (ROOT / '.github/actions/routing-bootstrap/action.yml').read_text()
        validate_short_bootstrap_paths(action, self.text)
        # Reproduce the observed 196-character golden relative path using a
        # Windows runner root. This is a boundary calculation, not causal proof.
        relative = ('engine/src/flutter/testing/ios_scenario_app/ios/Scenarios/ScenariosUITests/'
                    'golden_platform_view_large_cliprrect_with_transform_multiple_clips_impeller_'
                    'iPhone SE (3rd generation)_26.2_simulator.png')
        old = 'D:\\a\\_temp\\routing-bootstrap-platform-source\\sdk-install\\flutter\\' + relative.replace('/', '\\')
        new = 'D:\\a\\_temp\\rb\\s\\flutter\\' + relative.replace('/', '\\')
        self.assertGreater(len(old), 260)
        self.assertLess(len(new), 260)

    def test_inconsistent_or_lengthened_results_paths_are_rejected(self):
        action = (ROOT / '.github/actions/routing-bootstrap/action.yml').read_text()
        for key in ('rb/s', 'rb/p'):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'short private installation root'):
                validate_short_bootstrap_paths(action.replace(key, 'routing-bootstrap-platform-source/' + key), self.text)
        with self.assertRaisesRegex(ValueError, 'results disagree'):
            validate_short_bootstrap_paths(action, self.text.replace('$env:RUNNER_TEMP/rb/r', '$env:RUNNER_TEMP/old/results'))

    def test_sdk_long_paths_must_precede_setup_and_keep_lf(self):
        action = (ROOT / '.github/actions/routing-bootstrap/action.yml').read_text()
        for setting in ('core.longpaths true', 'core.autocrlf false', 'core.eol lf'):
            with self.subTest(setting=setting), self.assertRaisesRegex(ValueError, 'before setup'):
                validate_short_bootstrap_paths(action.replace('git config --global ' + setting, '# removed'), self.text)

    def test_missing_actual_platform_or_finish_step_is_rejected(self):
        self.reject('platform: windows', 'platform: linux', 'windows')
        self.reject('--platform android --finalize', '--platform android', 'post-test source finalization')
        self.reject("--platform '${{ matrix.platform }}' --finalize",
                    "--platform '${{ matrix.platform }}'", 'post-test source finalization')

    def test_patch_skip_and_app_local_receipts_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'actual patch chain'):
            validate_routing_bootstrap(self.text + '\n# PILIPLUSX_SKIP_POINTER_FILTER_PATCH=1\n')
        self.reject('path: ${{ env.ROUTING_RESULTS }}', 'path: app/ci-routing-results', 'outside clean App')

    def test_each_validation_and_finalization_requires_successful_preparation(self):
        guard = "if: ${{ !cancelled() && steps.prepare.outcome == 'success' }}"
        for job in ('app-source', 'platform-source'):
            body = routing_job(self.text, job)
            steps = re.split(r'^      - ', body, flags=re.M)
            for step in steps:
                if guard in step:
                    with self.subTest(job=job, step=step.splitlines()[0]):
                        broken = body.replace(step, step.replace(guard, 'if: always()'))
                        with self.assertRaisesRegex(ValueError, 'unprepared inputs'):
                            validate_routing_bootstrap(self.text.replace(body, broken))

    def test_receipts_are_uploaded_even_on_bootstrap_or_test_failure(self):
        for job in ('app-source', 'platform-source'):
            body = routing_job(self.text, job)
            broken = body.replace('if: always()', "if: ${{ success() }}")
            with self.subTest(job=job), self.assertRaisesRegex(ValueError, 'unconditionally'):
                validate_routing_bootstrap(self.text.replace(body, broken))

    def test_windows_failures_cannot_be_discarded(self):
        self.reject("if ($LASTEXITCODE -ne 0) { throw 'Flutter App tests failed' }",
                    '# discarded status', 'propagate native command failure')

    def test_existing_chrome_web_and_bundle_gates_remain_required(self):
        self.reject('flutter test --no-pub --platform chrome', '# chrome omitted', 'platform chrome')
        self.reject('flutter build web --target lib/main_web.dart --no-pub', '# web omitted', 'build web')
        self.reject('flutter build bundle --debug --no-pub', '# bundle omitted', 'build bundle')


if __name__ == '__main__':
    unittest.main()
