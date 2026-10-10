import copy
import importlib.util
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

SPEC = importlib.util.spec_from_file_location(
    'verify_routing_sources', Path(__file__).resolve().parents[1] / 'scripts/verify_routing_sources.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RoutingSourcesTest(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.media = self.root / 'media-kit'
        self.config = self.root / 'app/.dart_tool/package_config.json'
        self.config.parent.mkdir(parents=True)
        self.entries = []
        for name, relative in MODULE.PACKAGES.items():
            path = self.media / relative
            path.mkdir(parents=True)
            self.entries.append({'name': name, 'rootUri': path.as_uri()})

    def check(self, entries):
        self.config.write_text(json.dumps({'packages': entries}))
        return MODULE.verify(self.config, self.media)

    def test_all_packages_use_one_checkout(self):
        self.assertEqual(self.check(self.entries), MODULE.PACKAGES)

    def test_relative_package_uri_is_resolved_against_config(self):
        entries = copy.deepcopy(self.entries)
        for entry in entries:
            entry['rootUri'] = os.path.relpath(self.media / MODULE.PACKAGES[entry['name']], self.config.parent)
        self.assertEqual(self.check(entries), MODULE.PACKAGES)

    def test_cached_old_source_is_rejected(self):
        old = self.root / 'old-cache/media_kit'
        old.mkdir(parents=True)
        entries = copy.deepcopy(self.entries)
        entries[0]['rootUri'] = old.as_uri()
        with self.assertRaisesRegex(ValueError, 'supplied media-kit checkout'):
            self.check(entries)

    def test_missing_package_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Missing media-kit packages'):
            self.check(self.entries[1:])

    def test_duplicate_package_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate package'):
            self.check(self.entries + self.entries[:1])

    def test_nonlocal_uri_is_rejected(self):
        entries = copy.deepcopy(self.entries)
        entries[0]['rootUri'] = 'https://example.invalid/media_kit'
        with self.assertRaisesRegex(ValueError, 'Non-local'):
            self.check(entries)

    def test_unaccounted_media_kit_package_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unaccounted'):
            self.check(self.entries + [{'name': 'media_kit_old', 'rootUri': self.media.as_uri()}])

    def test_unrelated_packages_do_not_affect_verification(self):
        self.assertEqual(self.check(self.entries + [{'name': 'other', 'rootUri': 'unused'}]), MODULE.PACKAGES)


if __name__ == '__main__':
    unittest.main()
