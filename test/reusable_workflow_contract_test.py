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


def platform_job(text, name, indent=2):
    spaces = ' ' * indent
    block = re.search(r'^' + spaces + re.escape(name) + r':\n(.*?)(?=^' + spaces + r'[a-z][a-z_-]*:|\Z)',
                      text, re.M | re.S)
    if not block:
        raise ValueError('Missing platform job ' + name)
    return block.group(1)


def validate_platform_routing_calls(text):
    for name in ('linux_x64', 'win_x64'):
        body = platform_job(text, name, indent=4)
        for value, reason in (
                ('needs: routing-vector', 'captured routing vector'),
                ('uses: ./.github/workflows/' + name + '.yml', 'existing reusable workflow'),
                ('routing-mode: ${{ needs.routing-vector.outputs.routing-mode == \'true\' }}', 'routing mode'),
                ('app-sha: ${{ needs.routing-vector.outputs.app-sha }}', 'App SHA'),
                ('media-kit-sha: ${{ needs.routing-vector.outputs.media-kit-sha }}', 'media-kit SHA')):
            if value not in body:
                raise ValueError(name + ' misses ' + reason)


def validate_platform_source_workflow(text, platform, consumer, old_urls):
    inputs = text.split('  workflow_call:\n', 1)[1].split('  workflow_dispatch:', 1)[0]
    for value, reason in (
            ('routing-mode:\n', 'routing mode input'),
            ('required: false\n        default: false\n        type: boolean', 'optional false routing mode'),
            ('app-sha:\n', 'App SHA input'),
            ('media-kit-sha:\n', 'media-kit SHA input')):
        if value not in inputs:
            raise ValueError('Reusable workflow misses ' + reason)
    dispatch = text.split('  workflow_dispatch:\n', 1)[1].split('\njobs:', 1)[0]
    if ('routing-mode:\n' not in dispatch or
            'required: false\n        default: false\n        type: boolean' not in dispatch):
        raise ValueError(platform + ' direct dispatch must declare an explicit default-false routing-mode input')
    if 'app-sha:' in dispatch or 'media-kit-sha:' in dispatch:
        raise ValueError(platform + ' direct dispatch cannot claim an uncaptured source vector')
    job_name = 'build-linux-app' if platform == 'linux' else 'build-windows-app'
    body = platform_job(text, job_name)
    if 'name: %s x64 workflow' % ('Linux' if platform == 'linux' else 'Windows') not in body:
        raise ValueError(platform + ' job name must not claim source preparation before it succeeds')
    preflight = re.search(r'^      - name: Reject uncaptured routing dispatch before any production step\n(.*?)(?=^      - |\Z)',
                          body, re.M | re.S)
    if not preflight:
        raise ValueError(platform + ' must reject uncaptured direct routing dispatch')
    preflight_body = preflight.group(1)
    for token in ('inputs.routing-mode', "inputs.app-sha == ''", "inputs.media-kit-sha == ''",
                  "inputs.media-kit-sha != ''", "github.ref_name == 'routing/MK-ROUTING-20261011'", 'throw'):
        if token not in preflight_body:
            raise ValueError(platform + ' direct-dispatch refusal misses ' + token)
    if 'github.event_name' in preflight_body:
        raise ValueError(platform + ' must classify captured vectors independently of caller event name')
    first_step = re.search(r'^      - name: (.+)$', body, re.M)
    if not first_step or first_step.group(1) != 'Reject uncaptured routing dispatch before any production step':
        raise ValueError(platform + ' must run dispatch refusal before source or production setup')
    checkout = body.find('uses: actions/checkout@v4')
    for setting in ('git config --global core.longpaths true',
                    'git config --global core.autocrlf false',
                    'git config --global core.eol lf'):
        position = body.find(setting)
        if position < 0 or position >= checkout:
            raise ValueError(platform + ' must configure checkout before fetching sources')
    for value, reason in (
            ('repository: Goodwu/PiliPlusX', 'exact App repository'),
            ('ref: ${{ inputs.app-sha }}', 'exact App SHA'),
            ('path: app', 'App checkout path'),
            ('repository: Goodwu/media-kit', 'exact media-kit repository'),
            ('ref: ${{ inputs.media-kit-sha }}', 'exact media-kit SHA'),
            ('path: media-kit', 'media-kit checkout path'),
            ('persist-credentials: false', 'checkout credential removal'),
            ('uses: ./app/.github/actions/routing-bootstrap', 'existing shared bootstrap'),
            ('app-root: app', 'isolated App checkout root'),
            ('media-kit-root: media-kit', 'isolated media-kit checkout root'),
            ('app-sha: ${{ inputs.app-sha }}', 'exact bootstrap App SHA'),
            ('media-kit-sha: ${{ inputs.media-kit-sha }}', 'exact bootstrap media-kit SHA'),
            ('platform: ' + platform, 'real platform bootstrap'),
            ('python scripts/verify_routing_sources.py --app-root . --media-kit-root ../media-kit',
             'real package source verification'),
            ('flutter build bundle --debug --no-pub', 'current-source App bundle compilation'),
            ('scripts/prepare_routing_ci.py', 'source finalization'),
            ('--platform ' + platform + ' --finalize', 'platform source finalization'),
            ('stage = \'SOURCE_PREPARED_NATIVE_BLOCKED\'', 'accurate blocked stage'),
            ('status = \'%s-current-native-input-unavailable\'' % platform, 'platform-specific blocker'),
            (consumer, 'current native consumer identity'),
            ('currentProducerReceipt = $null', 'missing current producer receipt'),
            ('nativeInputRoot = $env:NATIVE_ROOT', 'local native root evidence'),
            ('appCommit = $env:APP_SHA', 'App SHA diagnostic'),
            ('mediaKitCommit = $env:MEDIA_KIT_SHA', 'media-kit SHA diagnostic'),
            ("bootstrapReceipt = (Join-Path $env:ROUTING_RESULTS 'bootstrap.json')", 'bootstrap receipt diagnostic'),
            (old_urls, 'legacy native download URL evidence'),
            ('if: ${{ always() && inputs.routing-mode }}', 'unconditional diagnostics upload'),
            ('if-no-files-found: error', 'diagnostic artifact integrity')):
        if value not in body:
            raise ValueError(platform + ' misses ' + reason)
    routing_start = body.find('      - name: Prepare routing receipts directory')
    legacy_start = body.find('      - name: Checkout ' + ('repository' if platform == 'linux' else 'code'))
    if routing_start < 0 or legacy_start <= routing_start:
        raise ValueError(platform + ' must keep a separate source-only lane')
    routing = body[routing_start:legacy_start]
    if 'verify_media_kit_lock.py' in routing:
        raise ValueError(platform + ' must not manufacture Android media-kit lock receipts')
    if 'flutter build linux --release' in routing or 'fastforge package --platform windows' in routing:
        raise ValueError(platform + ' routing mode must stop before native consumption')
    for step in re.split(r'^      - ', body[legacy_start:], flags=re.M):
        if step.strip():
            if 'if: ${{ !inputs.routing-mode' not in step:
                raise ValueError(platform + ' legacy production step is not disabled in routing mode')
            if "inputs.media-kit-sha == '' && github.ref_name != 'routing/MK-ROUTING-20261011'" not in step:
                raise ValueError(platform + ' legacy production step can bypass the direct-dispatch refusal')


def routing_job(text, name):
    block = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [a-z][a-z-]*:|\Z)',
                      text, re.M | re.S)
    if not block:
        raise ValueError('Missing routing job ' + name)
    return block.group(1)


def validate_python_bootstrap(text):
    """Keep macOS API tests and real parser provenance in the full test job."""
    body = routing_job(text, 'python-tests')
    for value, reason in (
            ('needs: source-vector', 'captured vector'),
            ('runs-on: macos-latest', 'real macOS signing APIs'),
            ('timeout-minutes: 45', 'bootstrap and full test timeout'),
            ('working-directory: app', 'App working directory'),
            ("ROUTING_RESULTS=%s\\n' \"$RUNNER_TEMP/rb/r\"", 'private results'),
            ("ROUTING_BOOTSTRAP_RECEIPT=%s\\n' \"$RUNNER_TEMP/rb/r/bootstrap.json\"", 'exact bootstrap receipt'),
            ('path: app\n', 'App checkout path'),
            ('path: media-kit\n', 'library checkout path'),
            ('EXPECTED_APP_SHA: ${{ inputs.app-sha || github.event.pull_request.head.sha || github.sha }}', 'exact App vector'),
            ('EXPECTED_MEDIA_KIT_SHA: ${{ needs.source-vector.outputs.media-kit-sha }}', 'exact library vector'),
            ('ref: ${{ inputs.app-sha || github.event.pull_request.head.sha || github.sha }}', 'exact App event HEAD'),
            ('ref: ${{ needs.source-vector.outputs.media-kit-sha }}', 'exact library checkout'),
            ('repository: Goodwu/media-kit', 'library repository'),
            ('uses: ./app/.github/actions/routing-bootstrap', 'real shared bootstrap'),
            ('app-root: app\n', 'bootstrap App root'),
            ('media-kit-root: media-kit\n', 'bootstrap library root'),
            ('app-sha: ${{ env.EXPECTED_APP_SHA }}', 'bootstrap App vector'),
            ('media-kit-sha: ${{ env.EXPECTED_MEDIA_KIT_SHA }}', 'bootstrap library vector'),
            ('platform: android', 'existing Android patch preparation'),
            ('git merge-base --is-ancestor FETCH_HEAD HEAD', 'App base gate'),
            ('scripts/prepare_routing_ci.py', 'post-test source finalization'),
            ('--platform android --finalize', 'post-test source finalization'),
            ('path: ${{ env.ROUTING_RESULTS }}', 'private receipt upload'),
            ('if-no-files-found: error', 'failure evidence')):
        if value not in body:
            raise ValueError('python-tests misses ' + reason)
    checkout = body.find('- uses: actions/checkout@v4')
    for setting in ('core.longpaths true', 'core.autocrlf false', 'core.eol lf'):
        position = body.find('git config --global ' + setting)
        if position < 0 or position >= checkout:
            raise ValueError('python-tests requires Git configuration before checkout')
    test_command = "python3 -m unittest discover -s test -p '*_test.py' -v"
    if test_command not in body:
        raise ValueError('python-tests must retain all Python modules')
    prepare = body.find('uses: ./app/.github/actions/routing-bootstrap')
    if body.find(test_command) < prepare:
        raise ValueError('python-tests must bootstrap before discovering tests')
    guard = "if: ${{ !cancelled() && steps.prepare.outcome == 'success' }}"
    steps = re.split(r'^      - ', body, flags=re.M)
    for step in steps:
        if test_command in step:
            for value in (guard, 'set -euo pipefail', 'test -f "$ROUTING_BOOTSTRAP_RECEIPT"',
                          'test -n "$FLUTTER_ROOT"', 'test -n "$PUB_CACHE"',
                          'python3 scripts/verify_hdr_channel.py', 'git diff --exit-code'):
                if value not in step:
                    raise ValueError('python-tests misses prepared test environment/failure propagation')
        if 'scripts/prepare_routing_ci.py' in step:
            for value in (guard, '--app-root .', '--media-kit-root ../media-kit', '--flutter-root "$FLUTTER_ROOT"',
                          '--private-root "${{ steps.prepare.outputs.private-root }}"', '--output "$ROUTING_RESULTS"',
                          '--expected-app-sha "$EXPECTED_APP_SHA"', '--expected-media-kit-sha "$EXPECTED_MEDIA_KIT_SHA"'):
                if value not in step:
                    raise ValueError('python-tests must finalize prepared sources even after test failure')
            if body.find('scripts/prepare_routing_ci.py') < body.find(test_command):
                raise ValueError('python-tests must finalize after tests')
    if 'continue-on-error:' in body:
        raise ValueError('python-tests must retain failed job status')
    artifacts = body.split('- uses: actions/upload-artifact@v4', 1)
    if len(artifacts) != 2 or 'if: always()' not in artifacts[1]:
        raise ValueError('python-tests must archive evidence unconditionally')


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
        if 'ref: ${{ inputs.app-sha || github.event.pull_request.head.sha || github.sha }}' not in body:
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
    validate_python_bootstrap(text)


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


class PythonBootstrapWiringTests(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / '.github/workflows/routing-source-integration.yml').read_text()
        self.body = routing_job(self.text, 'python-tests')

    def reject(self, before, after, reason):
        self.assertIn(before, self.body)
        with self.assertRaisesRegex(ValueError, reason):
            validate_python_bootstrap(self.text.replace(self.body, self.body.replace(before, after, 1)))

    def test_macOS_full_suite_uses_exact_bootstrap_and_failure_finalization(self):
        validate_python_bootstrap(self.text)

    def test_removing_bootstrap_or_private_receipt_is_rejected(self):
        self.reject('uses: ./app/.github/actions/routing-bootstrap', '# bootstrap omitted', 'shared bootstrap')
        self.reject('ROUTING_BOOTSTRAP_RECEIPT=%s', 'OTHER_RECEIPT=%s', 'bootstrap receipt')

    def test_checkout_root_vector_and_working_directory_are_enforced(self):
        for before, after in (('path: app\n', 'path: .\n'), ('path: media-kit\n', 'path: library\n'),
                              ('app-root: app\n', 'app-root: .\n'), ('media-kit-root: media-kit\n', 'media-kit-root: other\n'),
                              ('working-directory: app', 'working-directory: .'),
                              ('needs: source-vector', '# detached vector')):
            with self.subTest(before=before):
                self.reject(before, after, 'python-tests')

    def test_parser_only_discovery_cannot_replace_full_python_suite(self):
        self.reject("-p '*_test.py'", "-p 'parse_routing_manifest_test.py'", 'all Python modules')
        self.reject('runs-on: macos-latest', 'runs-on: ubuntu-latest', 'macOS signing APIs')

    def test_finalization_is_required_and_runs_after_failed_tests(self):
        self.reject('--platform android --finalize', '--platform android', 'post-test source finalization')
        self.reject("if: ${{ !cancelled() && steps.prepare.outcome == 'success' }}", "if: ${{ success() }}", 'prepared test environment')
        prefix, final = self.body.split('      - name: Finalize Python test source freshness and package roots', 1)
        broken = final.replace("if: ${{ !cancelled() && steps.prepare.outcome == 'success' }}", "if: ${{ success() }}", 1)
        with self.assertRaisesRegex(ValueError, 'even after test failure'):
            validate_python_bootstrap(self.text.replace(self.body, prefix + '      - name: Finalize Python test source freshness and package roots' + broken))
        with self.assertRaisesRegex(ValueError, 'failed job status'):
            validate_python_bootstrap(self.text.replace(self.body, self.body + '    continue-on-error: true\n'))

    def test_failure_receipts_and_real_environment_checks_are_required(self):
        self.reject('if: always()', 'if: ${{ success() }}', 'unconditionally')
        self.reject('test -n "$PUB_CACHE"', '# no cache check', 'prepared test environment')
        self.reject('test -n "$FLUTTER_ROOT"', '# no SDK check', 'prepared test environment')


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
        broken = body.replace('ref: ${{ inputs.app-sha || github.event.pull_request.head.sha || github.sha }}',
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


class LinuxWindowsRoutingSourceWiringTests(unittest.TestCase):
    def setUp(self):
        self.caller = (ROOT / '.github/workflows/build.yml').read_text()

    def test_callers_forward_the_single_exact_source_vector(self):
        validate_platform_routing_calls(self.caller)

    def test_linux_current_source_path_stops_before_native_consumer(self):
        text = (ROOT / '.github/workflows/linux_x64.yml').read_text()
        validate_platform_source_workflow(
            text, 'linux', 'media_kit_video/linux/CMakeLists.txt -> Flutter Linux CMake consumer',
            'https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_x86_64.zip')

    def test_windows_current_source_path_stops_before_native_consumer(self):
        text = (ROOT / '.github/workflows/win_x64.yml').read_text()
        validate_platform_source_workflow(
            text, 'windows', 'media_kit_video/windows/CMakeLists.txt -> Flutter Windows CMake consumer',
            'https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/20260811/mpv-dev-x86_64-20260811-git-ad59ff1.7z')

    def test_missing_source_sha_or_freshness_gate_is_rejected(self):
        linux = (ROOT / '.github/workflows/linux_x64.yml').read_text()
        with self.assertRaisesRegex(ValueError, 'exact media-kit SHA'):
            validate_platform_source_workflow(
                linux.replace('ref: ${{ inputs.media-kit-sha }}', 'ref: main'), 'linux',
                'media_kit_video/linux/CMakeLists.txt -> Flutter Linux CMake consumer',
                'https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_x86_64.zip')
        with self.assertRaisesRegex(ValueError, 'source finalization'):
            validate_platform_source_workflow(
                linux.replace('scripts/prepare_routing_ci.py', 'scripts/other.py'), 'linux',
                'media_kit_video/linux/CMakeLists.txt -> Flutter Linux CMake consumer',
                'https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_x86_64.zip')

    def test_current_native_producer_diagnostic_and_production_guard_are_mandatory(self):
        windows = (ROOT / '.github/workflows/win_x64.yml').read_text()
        with self.assertRaisesRegex(ValueError, 'missing current producer receipt'):
            validate_platform_source_workflow(
                windows.replace('currentProducerReceipt = $null', 'currentProducerReceipt = \'old.zip\''),
                'windows', 'media_kit_video/windows/CMakeLists.txt -> Flutter Windows CMake consumer',
                'https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/20260811/mpv-dev-x86_64-20260811-git-ad59ff1.7z')
        with self.assertRaisesRegex(ValueError, 'legacy production step'):
            validate_platform_source_workflow(
                windows.replace('        if: ${{ !inputs.routing-mode && inputs.media-kit-sha == \'\' && github.ref_name != \'routing/MK-ROUTING-20261011\' }}\n        uses: subosito/flutter-action@v2',
                                '        uses: subosito/flutter-action@v2'),
                'windows', 'media_kit_video/windows/CMakeLists.txt -> Flutter Windows CMake consumer',
                'https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/20260811/mpv-dev-x86_64-20260811-git-ad59ff1.7z')

    def test_dispatch_refusal_and_neutral_job_name_are_required(self):
        linux = (ROOT / '.github/workflows/linux_x64.yml').read_text()
        with self.assertRaisesRegex(ValueError, 'reject uncaptured direct routing dispatch'):
            validate_platform_source_workflow(
                linux.replace('Reject uncaptured routing dispatch before any production step',
                              'Remove dispatch refusal'), 'linux',
                'media_kit_video/linux/CMakeLists.txt -> Flutter Linux CMake consumer',
                'https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_x86_64.zip')
        with self.assertRaisesRegex(ValueError, 'job name must not claim'):
            validate_platform_source_workflow(
                linux.replace('name: Linux x64 workflow',
                              "name: ${{ inputs.routing-mode && 'SOURCE_PREPARED_NATIVE_BLOCKED' || 'Release Linux x64' }}"),
                'linux', 'media_kit_video/linux/CMakeLists.txt -> Flutter Linux CMake consumer',
                'https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_x86_64.zip')

    def test_routing_branch_direct_dispatch_counterexample_cannot_reach_legacy_lane(self):
        branch = 'routing/MK-ROUTING-20261011'
        app_sha = 'a' * 40
        media_sha = 'b' * 40

        def refused(event_name, ref_name, routing_mode, app, media):
            return ((routing_mode and (not app or not media)) or
                    (not routing_mode and bool(media)) or
                    (ref_name == branch and not routing_mode))

        def legacy_enabled(event_name, ref_name, routing_mode, media):
            return not routing_mode and not media and ref_name != branch

        # Direct dispatch exposes only routing-mode, so both SHAs are absent.
        # A reusable-workflow call from the same dispatch carries the vector outputs.
        self.assertTrue(refused('workflow_dispatch', branch, False, '', ''))
        self.assertFalse(legacy_enabled('workflow_dispatch', branch, False, ''))
        self.assertTrue(refused('workflow_dispatch', branch, True, '', ''))
        self.assertFalse(legacy_enabled('workflow_dispatch', branch, True, ''))
        self.assertTrue(refused('workflow_dispatch', 'main', True, '', ''))
        self.assertFalse(legacy_enabled('workflow_dispatch', 'main', True, ''))
        self.assertFalse(refused('workflow_dispatch', branch, True, app_sha, media_sha))  # captured routing dispatch
        self.assertFalse(legacy_enabled('workflow_dispatch', branch, True, media_sha))
        self.assertFalse(refused('pull_request', branch, True, app_sha, media_sha))  # captured routing PR
        self.assertFalse(legacy_enabled('pull_request', branch, True, media_sha))
        self.assertFalse(refused('workflow_dispatch', 'main', False, '', ''))  # ordinary direct dispatch
        self.assertTrue(legacy_enabled('workflow_dispatch', 'main', False, ''))


class RoutingNativeWorkflowTests(unittest.TestCase):
    def setUp(self):
        import sys
        sys.path.insert(0,str(ROOT/'scripts'))
        import verify_workflow_media_kit_refs as refs
        self.refs=refs
        self.texts={name:(ROOT/'.github/workflows'/name).read_text() for name in ('build.yml','pink.yml','routing-source-integration.yml')}

    def validate(self,texts=None):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            for name,text in (texts or self.texts).items():
                (Path(directory)/name).write_text(text)
            self.refs.verify_routing_workflows(Path(directory))

    def test_real_workflows_preserve_routing_build_and_consumer_gates(self):
        self.validate()

    def test_each_required_gate_removal_is_rejected(self):
        for workflow in ('build.yml','pink.yml'):
            block=self.refs.routing_block(self.texts[workflow])
            labels=re.findall(r'^            - name: (.+)$',block,re.M)
            for label in labels:
                if label.startswith(('Initialize','Checkout','Verify routing App','Set up')):
                    continue
                with self.subTest(workflow=workflow,gate=label):
                    body=self.refs.routing_step(block,label)
                    broken=dict(self.texts);broken[workflow]=broken[workflow].replace('            - name: '+label+'\n'+body,'',1)
                    with self.assertRaises(ValueError):self.validate(broken)

    def test_native_args_ABI_signature_finalize_and_selector_flow_cannot_be_omitted(self):
        checks={
          'Acquire explicitly accepted native input before Gradle':('--output','--receipt','--app-commit','--media-kit-commit','--readelf','--nm'),
          'Build routing Release APK with verified local arm64 input':('--check-prebuild','--manifest-parser','--android-project-arg=mediaKitLocalArm64Jar="$VERIFIED_JAR"','--android-project-arg=mediaKitArm64Only=true','--target-platform android-arm64','--no-pub'),
          'Verify routing APK native members ABI and signature':('--apk "$apk"','--manifest "$VERIFIED_MANIFEST"','--evidence-root "$VERIFIED_EVIDENCE"','--jar "$VERIFIED_JAR"','--receipt "$ROUTING_RESULTS/native-after.json"','scripts/verify_artifact.py','"$apksigner" verify --verbose'),
          'Finalize routing variant after build':('--finalize','--manifest-parser'),
          'Finalize original routing sources and freshness':('--finalize','--expected-app-sha','--expected-media-kit-sha'),
        }
        for workflow in ('build.yml','pink.yml'):
            block=self.refs.routing_block(self.texts[workflow])
            for label,tokens in checks.items():
                body=self.refs.routing_step(block,label)
                for token in tokens:
                    with self.subTest(workflow=workflow,gate=label,token=token):
                        broken=dict(self.texts);broken[workflow]=broken[workflow].replace(body,body.replace(token,'REMOVED',1),1)
                        with self.assertRaises(ValueError):self.validate(broken)

    def test_success_upload_cannot_be_replaced_by_failure_upload(self):
        for flavor in ('Android','Pink'):
            body=self.refs.routing_step(self.texts['build.yml'],f'Upload routing {flavor} candidate after parity')
            broken=dict(self.texts);broken['build.yml']=broken['build.yml'].replace(body,body.replace('success()','always()'))
            with self.subTest(flavor=flavor),self.assertRaisesRegex(ValueError,'candidate upload'):
                self.validate(broken)

    def test_failure_diagnostics_must_upload_even_if_native_rejected(self):
        for name in ('build.yml','pink.yml'):
            body=self.refs.routing_step(self.refs.routing_block(self.texts[name]),'Upload routing native failure diagnostics')
            broken=dict(self.texts);broken[name]=broken[name].replace(body,body.replace('always()','success()'))
            with self.subTest(workflow=name),self.assertRaises(ValueError):self.validate(broken)

    def test_staging_ID_and_final_native_sign_parity_cannot_be_omitted(self):
        for token in ('needs.android.outputs.staging-id','needs.pink.outputs.staging-id','scripts/verify_android_native_parity.py','--staging','--flavor'):
            broken=dict(self.texts);broken['build.yml']=broken['build.yml'].replace(token,'REMOVED')
            with self.subTest(token=token),self.assertRaises(ValueError):self.validate(broken)

    def test_source_callee_must_use_the_single_caller_capture(self):
        for token in ('SUPPLIED_MEDIA_SHA: ${{ inputs.media-kit-sha }}','library_head="$SUPPLIED_MEDIA_SHA"','inputs.app-sha || github.event.pull_request.head.sha || github.sha'):
            broken=dict(self.texts);broken['routing-source-integration.yml']=broken['routing-source-integration.yml'].replace(token,'REMOVED')
            with self.subTest(token=token),self.assertRaises(ValueError):self.validate(broken)

    def test_parity_failure_logs_and_dispatch_guard_cannot_be_omitted(self):
        for name,token in (('build.yml','Initialize parity failure diagnostics'),('build.yml','parity-diagnostics/source.txt'),('build.yml','tee "$RUNNER_TEMP/parity-diagnostics/parity.log"'),('build.yml','parity-diagnostics/freshness.txt'),('pink.yml','Reject uncaptured routing dispatch'),('pink.yml','exit 1'),('pink.yml','contents: write')):
            broken=dict(self.texts);broken[name]=broken[name].replace(token,'REMOVED',1)
            with self.subTest(workflow=name,token=token),self.assertRaises(ValueError):self.validate(broken)
        body=self.refs.routing_step(self.texts['build.yml'],'Upload routing parity diagnostics')
        broken=dict(self.texts);broken['build.yml']=broken['build.yml'].replace(body,body.replace('always()','success()'))
        with self.assertRaises(ValueError):self.validate(broken)

    def test_routing_candidate_never_uses_default_production_artifact(self):
        broken=dict(self.texts);broken['build.yml']=broken['build.yml'].replace('name: routing-android-candidate-','name: Android_arm64-v8a-')
        with self.assertRaises(ValueError):self.validate(broken)

    def test_production_lock_default_remains_fail_closed(self):
        import subprocess,tempfile,sys
        with tempfile.TemporaryDirectory() as directory:
            lock=Path(directory)/'pubspec.lock'
            commit='a'*40
            lock.write_text('packages:\n  media_kit:\n    description:\n      resolved-ref: '+commit+'\n      url: "https://github.com/Goodwu/media-kit.git"\n    source: git\n')
            argv=[sys.executable,str(ROOT/'scripts/verify_media_kit_lock.py'),str(lock),'--commit',commit]
            self.assertEqual(subprocess.run(argv,capture_output=True).returncode,0)
            lock.write_text(lock.read_text().replace('source: git','source: path'))
            self.assertNotEqual(subprocess.run(argv,capture_output=True).returncode,0)

    def test_production_ref_default_rejects_changed_immutable_pin(self):
        import subprocess,tempfile,sys
        with tempfile.TemporaryDirectory() as directory:
            workflow=Path(directory)/'release.yml';commit='a'*40
            workflow.write_text('flutter build apk\npython scripts/verify_media_kit_lock.py pubspec.lock --commit '+commit+'\n--media-kit-commit '+commit+'\n')
            argv=[sys.executable,str(ROOT/'scripts/verify_workflow_media_kit_refs.py'),'--workflow-dir',directory,'--commit',commit]
            self.assertEqual(subprocess.run(argv,capture_output=True).returncode,0)
            workflow.write_text(workflow.read_text().replace(commit,'b'*40))
            self.assertNotEqual(subprocess.run(argv,capture_output=True).returncode,0)


if __name__ == '__main__':
    unittest.main()
