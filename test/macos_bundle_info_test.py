"""CPU contract tests for the derived Runner Info.plist producer."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts/prepare_macos_bundle_info.py"
PENDING = "MediaKitSharedBootstrapPending"


class DerivedInfoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bundle info ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "Runner Info.plist"
        self.output = self.root / "Derived Info.plist"
        self.template = {
            "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleShortVersionString": "$(FLUTTER_BUILD_NAME)",
            "Nested": {"keep": ["value", 7]},
        }
        self.write_source(self.template)

    def write_source(self, values):
        self.source.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_XML))

    def run_generator(self, mode="<unset>", source=None, output=None):
        env = os.environ.copy()
        env.pop("PILIPLUSX_MPV_BUNDLE_MODE", None)
        if mode != "<unset>":
            env["PILIPLUSX_MPV_BUNDLE_MODE"] = mode
        return subprocess.run(
            [sys.executable, str(GENERATOR), str(source or self.source), str(output or self.output)],
            text=True, capture_output=True, env=env,
        )

    def test_unset_and_legacy_remove_key_while_bootstrap_adds_boolean(self):
        for mode in ("<unset>", "legacy"):
            result = self.run_generator(mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            values = plistlib.loads(self.output.read_bytes())
            self.assertNotIn(PENDING, values)
            self.assertEqual(values["Nested"], self.template["Nested"])
            self.assertEqual(values["CFBundleExecutable"], "$(EXECUTABLE_NAME)")
        result = self.run_generator("shared-candidate-bootstrap")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = plistlib.loads(self.output.read_bytes())
        self.assertIs(values[PENDING], True)
        self.assertEqual(values["Nested"], self.template["Nested"])
        self.assertEqual(self.source.read_bytes(), plistlib.dumps(self.template, fmt=plistlib.FMT_XML))
        result = self.run_generator("legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(PENDING, plistlib.loads(self.output.read_bytes()))

    def test_unknown_and_empty_mode_reject_without_changing_existing_output(self):
        self.assertEqual(self.run_generator("shared-candidate-bootstrap").returncode, 0)
        before = self.output.read_bytes()
        for mode in ("", "shared", "SHARED-CANDIDATE-BOOTSTRAP", "false"):
            result = self.run_generator(mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown PILIPLUSX_MPV_BUNDLE_MODE", result.stderr)
            self.assertEqual(self.output.read_bytes(), before)

    def test_same_bytes_do_not_replace_or_touch_output(self):
        self.assertEqual(self.run_generator("legacy").returncode, 0)
        before = (self.output.read_bytes(), self.output.stat().st_mtime_ns, self.output.stat().st_ino)
        self.assertEqual(self.run_generator("legacy").returncode, 0)
        after = (self.output.read_bytes(), self.output.stat().st_mtime_ns, self.output.stat().st_ino)
        self.assertEqual(after, before)

    def test_template_changes_are_reflected_and_missing_output_is_created(self):
        self.assertEqual(self.run_generator("shared-candidate-bootstrap").returncode, 0)
        self.output.unlink()
        changed = dict(self.template, AddedField="new")
        self.write_source(changed)
        self.assertEqual(self.run_generator("shared-candidate-bootstrap").returncode, 0)
        values = plistlib.loads(self.output.read_bytes())
        self.assertEqual(values["AddedField"], "new")
        self.assertIs(values[PENDING], True)

    def test_invalid_source_and_output_paths_fail_closed(self):
        self.assertEqual(self.run_generator("legacy").returncode, 0)
        original = self.output.read_bytes()

        bad_source = self.root / "bad.plist"
        bad_source.write_bytes(b"broken")
        for path, expected in ((bad_source, "cannot parse"),):
            result = self.run_generator("legacy", source=path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)
            self.assertEqual(self.output.read_bytes(), original)

        non_dict = self.root / "array.plist"
        non_dict.write_bytes(plistlib.dumps(["not", "dict"]))
        result = self.run_generator("legacy", source=non_dict)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("top level must be a dictionary", result.stderr)

        polluted = dict(self.template, **{PENDING: True})
        self.write_source(polluted)
        result = self.run_generator("legacy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reserved key", result.stderr)
        self.assertEqual(self.output.read_bytes(), original)
        self.write_source(self.template)

        alias = self.root / "alias.plist"
        alias.symlink_to(self.source)
        result = self.run_generator("legacy", output=alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be a symlink", result.stderr)
        source_link = self.root / "source-link.plist"
        source_link.symlink_to(self.source)
        result = self.run_generator("legacy", source=source_link)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not be a symlink", result.stderr)
        result = self.run_generator("legacy", source=self.source, output=self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different files", result.stderr)
        hardlink = self.root / "source-hardlink.plist"
        os.link(self.source, hardlink)
        result = self.run_generator("legacy", source=self.source, output=hardlink)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("same file", result.stderr)

        directory = self.root / "directory.plist"
        directory.mkdir()
        result = self.run_generator("legacy", output=directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular file", result.stderr)
        self.assertEqual(self.output.read_bytes(), original)

    def test_project_wires_one_early_prepare_and_three_matching_runner_configs(self):
        project = (ROOT / "macos/Runner.xcodeproj/project.pbxproj").read_text()
        prepare_id = "A04D04102026100500000001"
        output = "$(DERIVED_FILE_DIR)/PiliPlusX-BundleInfo.plist"
        self.assertEqual(project.count(f"{prepare_id} /* Prepare Bundle Info */"), 2)
        target = project.split("33CC10EC2044A3C60003C045 /* Runner */ = {", 1)[1].split("buildRules =", 1)[0]
        phases = target.split("buildPhases = (", 1)[1].split(");", 1)[0]
        self.assertLess(phases.index(prepare_id), phases.index("5190B88ACAD3AAF5B1766AE1"))
        phase = project.split(f"{prepare_id} /* Prepare Bundle Info */ = {{", 1)[1].split("\n\t\t};", 1)[0]
        self.assertIn("alwaysOutOfDate = 1;", phase)
        self.assertIn('"$(PROJECT_DIR)/Runner/Info.plist"', phase)
        self.assertIn('"$(PROJECT_DIR)/../scripts/prepare_macos_bundle_info.py"', phase)
        self.assertIn(f'"{output}"', phase)
        self.assertNotIn("TARGET_BUILD_DIR", phase)
        self.assertEqual(project.count(f'INFOPLIST_FILE = "{output}";'), 3)
        enforce = project.split("A04D04102026100300000001 /* Enforce modern mpv */ = {", 1)[1].split("\n\t\t};", 1)[0]
        enforce_inputs = enforce.split("inputPaths = (", 1)[1].split(");", 1)[0]
        self.assertEqual(enforce_inputs.count('"$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/'), 36)
        self.assertIn('"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"', enforce_inputs)
        self.assertIn('${PILIPLUSX_MPV_BUNDLE_MODE-legacy}', enforce)
        self.assertIn("must contain strict boolean true", (ROOT / "scripts/ensure_macos_mpv_bundle.sh").read_text())


if __name__ == "__main__":
    unittest.main()
