"""Exercise the pre-install pin reader without Flutter, yq or a YAML package."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
from routing_flutter_version import flutter_version


class FlutterVersionTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.pubspec = Path(temporary.name) / 'source with spaces' / 'pubspec.yaml'
        self.pubspec.parent.mkdir()

    def write(self, content):
        self.pubspec.write_text(content, encoding='utf-8')
        return self.pubspec

    def test_exact_pin_belongs_to_environment_not_dependencies(self):
        self.write('name: example\nenvironment:\n  sdk: ">=3.13.0"\n  flutter: 3.47.2\n'
                   'dependencies:\n  flutter:\n    sdk: flutter\n')
        self.assertEqual(flutter_version(self.pubspec), '3.47.2')

    def test_comments_blank_lines_and_crlf_do_not_change_pin(self):
        self.write('# environment: fake\r\nenvironment: # SDK contract\r\n\r\n'
                   '  # flutter: 1.0.0\r\n  flutter: 3.47.7  \r\n')
        self.assertEqual(flutter_version(self.pubspec), '3.47.7')

    def test_repository_contract_and_inline_platform_lists_are_supported(self):
        self.assertRegex(flutter_version(SCRIPTS.parent / 'pubspec.yaml'), r'^\d+\.\d+\.\d+$')
        self.write('environment:\n  flutter: 3.47.2\nother:\n'
                   '  platforms: [linux, macos]\n  ref: current # context: source\n')
        self.assertEqual(flutter_version(self.pubspec), '3.47.2')

    def test_missing_environment_cannot_borrow_a_dependency_version(self):
        self.write('dependencies:\n  flutter: 3.47.2\n')
        with self.assertRaises(ValueError):
            flutter_version(self.pubspec)

    def test_duplicate_or_inline_environment_is_rejected(self):
        for content in ('environment:\n  flutter: 3.47.2\nenvironment:\n  sdk: any\n',
                        'environment: {flutter: 3.47.2}\n',
                        'environment: null\n  flutter: 3.47.2\n'):
            with self.subTest(content=content), self.assertRaises(ValueError):
                flutter_version(self.write(content))

    def test_missing_or_nested_flutter_is_rejected(self):
        for block in ('  sdk: any\n', '  other:\n    flutter: 3.47.2\n'):
            with self.subTest(block=block), self.assertRaises(ValueError):
                flutter_version(self.write('environment:\n' + block))

    def test_duplicate_pin_is_rejected_even_if_one_value_is_invalid(self):
        for other in ('3.47.2', 'any'):
            with self.subTest(other=other), self.assertRaises(ValueError):
                flutter_version(self.write(f'environment:\n  flutter: 3.47.2\n  flutter: {other}\n'))

    def test_unpinned_or_unsupported_syntax_is_rejected(self):
        for value in ('any', 'stable', '^3.47.2', '>=3.47.2', '3.47', '3.47.2-beta',
                      '"3.47.2"', '', '3.47.2 # comment'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                flutter_version(self.write(f'environment:\n  flutter: {value}\n'))

    def test_quoted_keys_and_scalar_continuations_cannot_hide_another_pin(self):
        for content in (
            'environment:\n  flutter: 3.47.2\n  "flutter": stable\n',
            'environment:\n  flutter: 3.47.2\n  \'flutter\': stable\n',
            'environment:\n  flutter: 3.47.2\n"environment":\n  flutter: stable\n',
            'environment:\n  flutter: 3.47.2\n"\\u0065nvironment": {}\n',
            'environment:\n  flutter: 3.47.2\n    invalid-continuation\n',
            'environment:\n  flutter: 3.47.2\n  <<: *another_environment\n',
            'description: "hello\nenvironment:\n  flutter: 3.47.2\nend: world"\n',
            'other:\n  value: "hello\nenvironment:\n  flutter: 3.47.2\nend: world"\n',
            'other:\n  - value: "hello\nenvironment:\n  flutter: 3.47.2\nend: world"\n',
        ):
            with self.subTest(content=content), self.assertRaises(ValueError):
                flutter_version(self.write(content))

    def test_cli_emits_only_the_version_and_accepts_paths_with_spaces(self):
        self.write('environment:\n  flutter: 3.47.2\n')
        result = subprocess.run([sys.executable, str(SCRIPTS / 'routing_flutter_version.py'),
                                 str(self.pubspec)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '3.47.2\n')
        self.assertEqual(result.stderr, '')

    def test_cli_refuses_bad_or_missing_inputs_without_version_output(self):
        self.write('environment:\n  flutter: stable\n')
        for path in (self.pubspec, self.pubspec.with_name('missing.yaml')):
            with self.subTest(path=path):
                result = subprocess.run([sys.executable, str(SCRIPTS / 'routing_flutter_version.py'),
                                         str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')
                self.assertNotEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
