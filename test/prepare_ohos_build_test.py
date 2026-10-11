"""Exercise isolated OHOS preparation independently of package-name casing."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare_ohos_build.py'
OLD = ('name: PiliPlus', '  sdk: ">=3.13.0"', '  flutter: 3.47.2',
       '  flex_seed_scheme: ^5.0.0', '  material_ui: ^1.0.0')
NEW = ('name: piliplus', '  sdk: ">=3.12.0 <4.0.0"', '  flutter: any',
       '  flex_seed_scheme: ^4.0.1', '  material_ui: 1.0.0')


def pubspec(states):
    return '\n'.join((states[0], 'environment:', *states[1:3],
        'dependencies:', '  flutter:', '    sdk: flutter', *states[3:],
        '  media_kit_libs_video: 1.0.5', 'dependency_overrides:',
        '  media_kit_libs_windows_video:', '    path: /desktop-only',
        '  media_kit_libs_video:', '    path: /desktop-only', ''))


class OhosBuildPreparationTests(unittest.TestCase):
    def prepare(self, text, *, lowercase_imports=False, barriers=3):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        source, output = root / 'source', root / 'output'
        source.mkdir()
        (source / 'pubspec.yaml').write_text(text)
        (source / 'pubspec_overrides.yaml').write_text('local-only override')
        lib = source / 'lib'
        lib.mkdir()
        package = 'piliplus' if lowercase_imports else 'PiliPlus'
        (lib / 'example.dart').write_text(f"import 'package:{package}/example.dart';\n")
        controller = lib / 'plugin/pl_player/controller.dart'
        controller.parent.mkdir(parents=True)
        controller.write_text('await platform.disposeForRebuild();\n' * barriers)
        before = {p.relative_to(source): p.read_bytes() for p in source.rglob('*') if p.is_file()}
        result = subprocess.run([sys.executable, str(SCRIPT), '--workspace', str(source),
                                 '--output', str(output)], text=True, capture_output=True)
        self.assertEqual({p.relative_to(source): p.read_bytes() for p in source.rglob('*') if p.is_file()}, before)
        return result, output

    def assert_prepared(self, states, *, lowercase_imports=False):
        self.assert_prepared_text(pubspec(states), lowercase_imports=lowercase_imports)

    def assert_prepared_text(self, text, *, lowercase_imports=False):
        result, output = self.prepare(text, lowercase_imports=lowercase_imports)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = (output / 'pubspec.yaml').read_text().splitlines()
        for expected in NEW:
            self.assertIn(expected, lines)
        for old in OLD:
            self.assertNotIn(old, lines)
        self.assertNotIn('media_kit_libs_video:', (output / 'pubspec.yaml').read_text())
        self.assertNotIn('media_kit_libs_windows_video:', (output / 'pubspec.yaml').read_text())
        self.assertFalse((output / 'pubspec_overrides.yaml').exists())
        self.assertIn('package:piliplus/', (output / 'lib/example.dart').read_text())
        self.assertEqual((output / 'lib/plugin/pl_player/controller.dart').read_text().count('await platform.disposeForRebuild();'), 3)

    def test_legacy_uppercase_package_is_prepared(self):
        self.assert_prepared(OLD)

    def test_current_pubspec_prepares_in_isolated_fixture(self):
        text = (SCRIPT.parents[1] / 'pubspec.yaml').read_text()
        self.assert_prepared_text(text, lowercase_imports='name: piliplus\n' in text)

    def test_lowercase_package_still_converts_normal_toolchain_and_dependencies(self):
        self.assert_prepared((NEW[0], *OLD[1:]), lowercase_imports=True)

    def test_all_prepared_constraints_are_accepted(self):
        self.assert_prepared(NEW, lowercase_imports=True)

    def test_mixed_known_old_and_new_constraints_are_normalized(self):
        self.assert_prepared((NEW[0], NEW[1], OLD[2], NEW[3], OLD[4]), lowercase_imports=True)

    def test_unknown_constraint_drift_is_rejected(self):
        for index, value in enumerate(('name: other', '  sdk: ">=3.14.0"',
                '  flutter: 3.48.0', '  flex_seed_scheme: ^6.0.0', '  material_ui: ^2.0.0')):
            with self.subTest(value=value):
                states = list(NEW)
                states[index] = value
                result, _ = self.prepare(pubspec(states), lowercase_imports=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('OHOS preparation expected', result.stderr)

    def test_duplicate_or_ambiguous_constraint_is_rejected(self):
        for extra in (OLD[1], NEW[1], '  sdk: ">=3.14.0"'):
            with self.subTest(extra=extra):
                text = pubspec(NEW).replace(NEW[1], NEW[1] + '\n' + extra)
                result, _ = self.prepare(text, lowercase_imports=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('OHOS preparation expected', result.stderr)

    def test_missing_field_and_duplicate_section_are_rejected(self):
        for text in (pubspec(NEW).replace(NEW[1] + '\n', ''),
                     pubspec(NEW) + 'environment:\n' + NEW[1] + '\n'):
            with self.subTest(text=text):
                result, _ = self.prepare(text, lowercase_imports=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('OHOS preparation expected', result.stderr)

    def test_uppercase_package_keeps_import_drift_gate(self):
        result, _ = self.prepare(pubspec(OLD), lowercase_imports=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no package:PiliPlus imports', result.stderr)

    def test_lowercase_package_keeps_teardown_barrier_gate(self):
        result, _ = self.prepare(pubspec(NEW), lowercase_imports=True, barriers=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exactly three real media-kit async', result.stderr)


if __name__ == '__main__':
    unittest.main()
