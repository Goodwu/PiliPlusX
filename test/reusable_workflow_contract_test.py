"""Regression for the two Apple reusable workflows' required source input.

This checks the repository's existing four-space jobs layout, not arbitrary
YAML. Actual GitHub workflow validation remains a separate integration gate.
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
        self.assertIn('verify_routing_sources.py', source)
        self.assertIn('verify_hdr_channel.py', source)
        self.assertIn('flutter test --no-pub', source)
        self.assertIn('flutter analyze --no-pub', source)
        self.assertIn('source-resolution-after.json', source)
        self.assertIn('group: routing-source-checks-${{ github.workflow }}-', source)

    def test_callees_keep_required_ref_and_release_guards(self):
        for name in ('ios', 'mac'):
            text = (ROOT / f'.github/workflows/{name}.yml').read_text()
            self.assertRegex(text, r'(?s)      ref:\n.*?        required: true\n')
        mac = (ROOT / '.github/workflows/mac.yml').read_text()
        self.assertIn('run_macos_shared_release.py --preflight', mac)


if __name__ == '__main__':
    unittest.main()
