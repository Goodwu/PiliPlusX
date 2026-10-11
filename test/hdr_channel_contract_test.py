"""Negative cases for the platform-specific HDR channel and routing hand-off."""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from verify_hdr_channel import ANDROID, FILES, verify


class HdrChannelContractTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in (*FILES, "lib/plugin/pl_player/hdr_output.dart", "lib/plugin/pl_player/controller.dart", "lib/plugin/pl_player/models/player_lifecycle_ports.dart"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def replace(self, name, old, new):
        path = self.root / name
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new))

    def test_current_contract(self):
        self.assertEqual(verify(self.root), [])

    def test_pink_package_rename_preserves_channel(self):
        self.replace(ANDROID, "com.example.piliplusx", "tv.danmaku.bili")
        self.assertEqual(verify(self.root), [])

    def test_missing_operation_fails(self):
        self.replace(ANDROID, '"resetOutput"', '"removedReset"')
        self.assertTrue(any("resetOutput" in error for error in verify(self.root)))

    def test_other_platform_still_requires_probe(self):
        self.replace("ios/Runner/AppDelegate.swift", '"probe"', '"removedProbe"')
        self.assertTrue(any("probe" in error for error in verify(self.root)))

    def test_package_coupled_channel_fails(self):
        self.replace(ANDROID, "piliplusx/hdr_capabilities", "com.example.piliplusx/hdr_capabilities")
        self.assertTrue(any("package-coupled" in error for error in verify(self.root)))

    def test_android_probe_reintroduction_fails(self):
        self.replace(ANDROID, 'call.method == "setWindowHdrMode"', 'call.method == "probe"')
        self.assertTrue(any("delegate" in error for error in verify(self.root)))

    def test_source_query_cannot_be_removed(self):
        self.replace("lib/plugin/pl_player/hdr_output.dart", "sources: sources", "sources: const []")
        self.assertTrue(any("sources: sources" in error for error in verify(self.root)))

    def test_default_session_factory_cannot_be_replaced_by_null(self):
        self.replace("lib/plugin/pl_player/models/player_lifecycle_ports.dart",
                     "HdrVideoSession(player, target: target)", "null")
        self.assertTrue(any("real media-kit Session" in e for e in verify(self.root)))

    def test_android_factory_cannot_default_to_false(self):
        self.replace("lib/plugin/pl_player/models/player_lifecycle_ports.dart",
                     "androidSessionOverride ?? Platform.isAndroid", "androidSessionOverride ?? false")
        self.assertTrue(any("actual platform" in e for e in verify(self.root)))

    def test_initial_or_refresh_cannot_drop_snapshot(self):
        name = "lib/plugin/pl_player/controller.dart"
        text = (self.root / name).read_text()
        old = "options: dataSource.routeOptions ?? _sourceRouteOptions"
        self.assertEqual(text.count(old), 2)
        for index in (0, 1):
            parts = text.split(old)
            (self.root / name).write_text(parts[0] + (old if index else "options: null") +
                                          parts[1] + ("options: null" if index else old) + parts[2])
            self.assertTrue(any("source options snapshot" in e for e in verify(self.root)))

    def test_missing_file_is_reported(self):
        (self.root / ANDROID).unlink()
        self.assertTrue(any("missing contract file" in error for error in verify(self.root)))


if __name__ == "__main__":
    unittest.main()
