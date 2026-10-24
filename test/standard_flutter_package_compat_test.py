"""Standard Flutter compatibility removes only the approved pointer argument."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/prepare_standard_flutter_package_compat.py'
ARGUMENT = b'pointerDownFilter: _allowOuterVideoPointer,'


class StandardFlutterCompatibilityTests(unittest.TestCase):
    def run_compat(self, source):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        workspace = Path(temporary.name) / 'workspace'
        view = workspace / 'lib/pages/video/view.dart'
        view.parent.mkdir(parents=True)
        view.write_bytes(source)
        package = Path(temporary.name) / 'private-package'
        util = package / 'lib/src/util.dart'
        util.parent.mkdir(parents=True)
        before_package = b'bool ohos = defaultTargetPlatform == TargetPlatform.ohos;\n'
        util.write_bytes(before_package)
        config = workspace / '.dart_tool/package_config.json'
        config.parent.mkdir()
        config.write_text(json.dumps({'packages': [{
            'name': 'flutter_inappwebview_platform_interface', 'rootUri': package.as_uri(),
        }]}))
        result = subprocess.run([sys.executable, str(SCRIPT), '--workspace', str(workspace)],
                                text=True, capture_output=True)
        return result, view.read_bytes(), util.read_bytes(), before_package

    def test_complete_argument_removal_preserves_every_other_byte(self):
        for indent, newline in ((b' ' * 10, b'\n'), (b' ' * 12, b'\n'), (b'\t', b'\n'),
                                (b' ' * 10, b'\r\n')):
            with self.subTest(indent=indent, newline=newline):
                argument = indent + ARGUMENT + newline
                before = b'// keep UTF-8: \xe7\xa4\xba\xe4\xbe\x8b' + newline + argument + b'const keep = true;' + newline
                result, view, util, _ = self.run_compat(before)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(view, before.replace(argument, b'', 1))
                self.assertEqual(util, b'bool ohos = false;\n')

    def test_current_source_argument_and_rest_of_view_are_preserved(self):
        source = (ROOT / 'lib/pages/video/view.dart').read_bytes()
        line = next(line for line in source.splitlines(keepends=True) if ARGUMENT in line)
        self.assertEqual(line.strip(), ARGUMENT)
        result, view, _, _ = self.run_compat(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(view, source.replace(line, b'', 1))

    def test_missing_duplicate_or_unknown_argument_rejects_before_any_write(self):
        approved = b' ' * 10 + ARGUMENT + b'\n'
        cases = (b'const unrelated = true;\n', approved * 2,
                 b'          pointerDownFilter: anotherCallback,\n',
                 approved + b'          pointerDownFilter: anotherCallback,\n',
                 b'          pointerDownFilter:\n            _allowOuterVideoPointer,\n',
                 approved.rstrip(b'\n') + b' // unapproved comment\n',
                 approved.rstrip(b'\n') + b' anotherOperation();\n')
        for source in cases:
            with self.subTest(source=source):
                result, view, util, before_package = self.run_compat(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('pointer-filter', result.stderr)
                self.assertEqual(view, source)
                self.assertEqual(util, before_package)


if __name__ == '__main__':
    unittest.main()
