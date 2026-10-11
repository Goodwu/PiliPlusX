"""Exercise local package-root URI handling for OHOS package patches."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory
from nturl2path import url2pathname as windows_url2pathname
import unittest

from scripts.prepare_ohos_package_patches import package_root


class PackageRootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name) / "workspace"
        self.workspace.mkdir()
        self.package = Path(self.temporary.name) / "package % source"
        self.package.mkdir()
        self.config = self.workspace / ".dart_tool/package_config.json"
        self.config.parent.mkdir()

    def resolve(self, root_uri):
        self.config.write_text(
            json.dumps({"packages": [{"name": "extended_nested_scroll_view",
                                      "rootUri": root_uri}]}),
            encoding="utf-8",
        )
        return package_root(self.workspace, "extended_nested_scroll_view")

    def test_posix_or_native_absolute_file_uri_resolves_current_package(self):
        self.assertEqual(self.resolve(self.package.as_uri()), self.package.resolve())

    def test_localhost_authority_is_accepted(self):
        uri = self.package.as_uri().replace("file:///", "file://localhost/", 1)
        self.assertEqual(self.resolve(uri), self.package.resolve())

    def test_encoded_space_and_percent_are_decoded_once(self):
        uri = self.package.as_uri()
        self.assertIn("%20", uri)
        self.assertIn("%25", uri)
        self.assertEqual(self.resolve(uri), self.package.resolve())

    def test_nonlocal_authority_query_fragment_and_nonfile_scheme_are_rejected(self):
        uri = self.package.as_uri()
        invalid = (
            "file://remote.invalid" + uri.removeprefix("file://"),
            uri + "?query=1",
            uri + "#fragment",
            "https://example.invalid/package",
            uri.replace("file:///", "file://LOCALHOST/", 1),
        )
        for root_uri in invalid:
            with self.subTest(root_uri=root_uri):
                with self.assertRaises(SystemExit):
                    self.resolve(root_uri)

    def test_windows_file_url_path_conversion(self):
        self.assertEqual(
            windows_url2pathname("/D:/Users/A%20B/100%25"),
            r"D:\Users\A B\100%",
        )
        self.assertEqual(
            windows_url2pathname("/D:/Users/A%2520B"),
            r"D:\Users\A%20B",
        )


if __name__ == "__main__":
    unittest.main()
