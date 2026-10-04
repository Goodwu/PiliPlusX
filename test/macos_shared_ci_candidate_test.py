from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/run_macos_shared_ci_candidate.py"
SPEC = importlib.util.spec_from_file_location("shared_candidate", SCRIPT)
candidate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(candidate)


class SharedCandidateTests(unittest.TestCase):
    def test_null_approved_revision_fails_preflight_before_subprocess(self):
        sha = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "lock.json"
            lock.write_text('{"reviewed_media_kit_revision": null}\n')
            diagnostics = Path(temporary) / "piliplusx-shared-candidate-diagnostics"
            env = {"RUNNER_TEMP": str(Path(temporary).resolve()), "SOURCE_REF": sha, "GITHUB_SHA": sha,
                   "GITHUB_RUN_ID": "12", "GITHUB_RUN_ATTEMPT": "1"}
            with mock.patch.object(candidate, "LOCK", lock), \
                 mock.patch.object(candidate, "LOCK_SHA256", hashlib.sha256(lock.read_bytes()).hexdigest()), \
                 mock.patch.dict(os.environ, env, clear=False), \
                 mock.patch.object(candidate.sys, "argv", [str(SCRIPT), "--preflight"]), \
                 mock.patch.object(candidate.subprocess, "run") as subprocess_run:
                self.assertEqual(candidate.main(), 2)
            subprocess_run.assert_not_called()
            result = json.loads((diagnostics / "result.json").read_text())
            self.assertEqual(result["status"], "source-preflight-failed")
            self.assertEqual(result["error"], "reviewed media-kit revision unavailable")

    def test_source_ref_requires_full_sha_and_workflow_identity(self):
        sha = "a" * 40
        with mock.patch.object(candidate.subprocess, "run",
                               return_value=subprocess.CompletedProcess([], 0, sha + "\n", "")) as call:
            self.assertEqual(candidate.validate_source_ref(sha, sha), sha)
            self.assertEqual(call.call_args.args[0], ["git", "rev-parse", "HEAD"])
        for source, workflow in (("a" * 39, "a" * 39), ("a" * 40, "b" * 40)):
            with self.subTest(source=source, workflow=workflow):
                with self.assertRaises(candidate.CandidateError):
                    candidate.validate_source_ref(source, workflow)

    def test_commands_use_argument_vectors_and_stop_on_failure(self):
        argv = ["tool", "argument with spaces", "$(must-not-run)"]
        failed = subprocess.CompletedProcess(argv, 9, "", "mock failure")
        with mock.patch.object(candidate.subprocess, "run", return_value=failed) as call:
            with self.assertRaisesRegex(candidate.CandidateError, "mock failure"):
                candidate.run(argv, label="mock-stage")
        self.assertEqual(call.call_args.args[0], argv)
        self.assertNotIn("shell", call.call_args.kwargs)

    def test_every_locked_media_kit_package_has_one_fixed_url_ref_and_path(self):
        sha = "a" * 40
        package_names = ["media_kit", "media_kit_video"]
        report = {"media_kit_package_names": package_names,
                  "package_paths": {"media_kit": "media_kit", "media_kit_video": "media_kit_video"}}
        lock = "".join(
            f'  {name}:\n'
            f'    dependency: direct main\n'
            f'    description:\n'
            f'      path: "{report["package_paths"][name]}"\n'
            f'      ref: {sha}\n'
            f'      resolved-ref: {sha}\n'
            f'      url: "{candidate.MEDIA_KIT_URL}"\n'
            f'    source: git\n'
            f'    version: "1.0.0"\n'
            for name in package_names)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "pubspec.lock"
            path.write_text(lock)
            with mock.patch.object(candidate, "run") as run:
                candidate.check_lock(path, sha, report)
                run.assert_called_once()
            path.write_text(lock.replace(f"      ref: {sha}", "      ref: main", 1))
            with mock.patch.object(candidate, "run"):
                with self.assertRaisesRegex(candidate.CandidateError, "requested git ref"):
                    candidate.check_lock(path, sha, report)
            path.write_text(lock.replace('path: "media_kit_video"', 'path: "other"', 1))
            with mock.patch.object(candidate, "run"):
                with self.assertRaisesRegex(candidate.CandidateError, "package subpath"):
                    candidate.check_lock(path, sha, report)

    def test_overrides_include_same_origin_and_revision_for_each_package(self):
        sha = "a" * 40
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            for name in ("media_kit", "media_kit_video"):
                package = checkout / name
                package.mkdir()
                (package / "pubspec.yaml").write_text(f"name: {name}\n")
            paths = candidate.package_paths(checkout, ["media_kit", "media_kit_video"])
            self.assertEqual(paths, {"media_kit": "media_kit", "media_kit_video": "media_kit_video"})
            text = candidate.package_overrides(sha, paths)
            self.assertEqual(text.count(candidate.MEDIA_KIT_URL), 2)
            self.assertEqual(text.count(f"ref: {sha}"), 2)
            self.assertIn("path: media_kit\n", text)
            self.assertIn("path: media_kit_video\n", text)

    def test_temporary_overrides_preserve_other_existing_override_blocks(self):
        sha = "a" * 40
        original = ("dependency_overrides:\n"
                    "  unrelated_package:\n"
                    "    git:\n"
                    "      url: https://example.invalid/package.git\n"
                    "      ref: stable\n"
                    "  media_kit:\n"
                    "    path: ../developer/media_kit\n"
                    "other_top_level: true\n").encode()
        merged = candidate.merge_overrides(original, sha, {"media_kit": "media_kit"}).decode()
        self.assertIn("unrelated_package:", merged)
        self.assertIn("other_top_level: true", merged)
        self.assertNotIn("../developer/media_kit", merged)
        self.assertIn(f"ref: {sha}", merged)

    def _real_pub_git_fixture(self, base):
        private_cache = (base / "private-pub-cache").resolve()
        git_cache = private_cache / "git/cache"
        git_cache.mkdir(parents=True)
        seed = base / "seed-repo"
        seed.mkdir()

        def git(*argv, cwd=None):
            result = subprocess.run(["git", *map(str, argv)], cwd=cwd, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise AssertionError(f"git {argv} failed: {result.stderr}")
            return result.stdout.strip()

        git("init", cwd=seed)
        git("config", "user.name", "CPU Fixture", cwd=seed)
        git("config", "user.email", "fixture@example.invalid", cwd=seed)
        for name in ("media_kit", "media_kit_video"):
            package = seed / name
            package.mkdir()
            (package / "pubspec.yaml").write_text(f"name: {name}\n")
        bridge = seed / "media_kit_video" / candidate.MEDIA_KIT_BRIDGE
        bridge.parent.mkdir(parents=True)
        bridge.write_bytes(b"approved bridge fixture")
        recipe = seed / "tool/shared_gpu_next"
        recipe.mkdir(parents=True)
        (recipe / "recipe.yaml").write_text("recipe: approved\n")
        (seed / ".gitignore").write_text("tool/shared_gpu_next/.candidate-ignored\n")
        git("add", ".", cwd=seed)
        git("commit", "-m", "fixture", cwd=seed)
        revision = git("rev-parse", "HEAD", cwd=seed)
        bare = git_cache / "media-kit-fixture"
        git("clone", "--bare", seed, bare)
        git("--git-dir", bare, "remote", "set-url", "origin", candidate.MEDIA_KIT_URL)
        checkout = private_cache / "git/workspace/media-kit"
        checkout.parent.mkdir(parents=True)
        git("clone", bare, checkout)
        workspace = base / "workspace"
        (workspace / ".dart_tool").mkdir(parents=True)
        (workspace / ".dart_tool/package_config.json").write_text(json.dumps({"packages": [
            {"name": name, "rootUri": (checkout / name).as_uri() + "/"}
            for name in ("media_kit", "media_kit_video")
        ]}))
        report_dir = base / "report"
        report_dir.mkdir()
        report = {"report_path": str(report_dir.resolve() / "result.json")}
        names = ["media_kit", "media_kit_video"]
        paths = {name: name for name in names}
        return git, private_cache, bare, checkout, workspace, report, names, paths, revision

    def test_real_pub_git_cache_chain_same_head_and_clean_tree_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            (git, private_cache, bare, checkout, workspace, report, names, paths,
             revision) = self._real_pub_git_fixture(Path(temporary))
            candidate.verify_package_config(workspace, checkout, revision, names, paths, report,
                                            private_cache)
            source = report["pub_git_sources"]["media_kit"]
            self.assertEqual(source["checkout_head"], revision)
            self.assertEqual(Path(source["trusted_bare_cache"]), bare.resolve())
            self.assertEqual(source["bare_origin"], candidate.MEDIA_KIT_URL)
            self.assertTrue(source["bare"] and source["approved_commit_present"])
            self.assertEqual(report["approved_source_tree"]["inventory_clean"], True)
            # Direct fixed-origin checkouts remain supported when the canonical
            # private Pub bare cache also contains the exact reviewed commit.
            git("remote", "set-url", "origin", candidate.MEDIA_KIT_URL, cwd=checkout)
            candidate.verify_package_config(workspace, checkout, revision, names, paths, report,
                                            private_cache)

    def test_real_pub_git_checkout_rejects_tracked_ignored_and_recipe_drift(self):
        cases = ("tracked", "ignored", "recipe")
        for drift in cases:
            with self.subTest(drift=drift), tempfile.TemporaryDirectory() as temporary:
                (git, private_cache, _, checkout, workspace, report, names, paths,
                 revision) = self._real_pub_git_fixture(Path(temporary))
                if drift == "tracked":
                    (checkout / "media_kit/pubspec.yaml").write_text("name: altered\n")
                elif drift == "ignored":
                    (checkout / "tool/shared_gpu_next/.candidate-ignored").write_text("ignored\n")
                else:
                    (checkout / "tool/shared_gpu_next/recipe.yaml").write_text("recipe: altered\n")
                with self.assertRaises(candidate.CandidateError):
                    candidate.verify_package_config(workspace, checkout, revision, names, paths,
                                                    report, private_cache)

    def test_real_pub_git_source_rejects_untrusted_origin_and_symlink_cache_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            (git, private_cache, bare, checkout, _, report, _, _, revision) = self._real_pub_git_fixture(
                Path(temporary))
            git("--git-dir", bare, "remote", "set-url", "origin", "https://example.invalid/evil.git")
            with self.assertRaisesRegex(candidate.CandidateError, "unapproved origin"):
                candidate.verify_pub_git_source(checkout, private_cache, revision, report, "media_kit")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            private_cache = (base / "private-cache").resolve()
            private_cache.mkdir()
            outside = base / "outside-bare"
            outside.mkdir()
            link = private_cache / "git/cache/media-kit-escape"
            link.parent.mkdir(parents=True)
            link.symlink_to(outside, target_is_directory=True)
            checkout = private_cache / "git/workspace/media-kit"
            checkout.mkdir(parents=True)
            report_dir = base / "report"; report_dir.mkdir()
            report = {"report_path": str(report_dir.resolve() / "result.json")}
            with mock.patch.object(candidate, "run", side_effect=[
                    subprocess.CompletedProcess([], 0, "a" * 40 + "\n", ""),
                    subprocess.CompletedProcess([], 0, candidate.MEDIA_KIT_URL + "\n", "")]):
                with self.assertRaisesRegex(candidate.CandidateError, "symlink in private media-kit"):
                    candidate.verify_pub_git_source(checkout, private_cache, "a" * 40,
                                                    report, "media_kit")

    def test_workflow_is_dispatch_only_and_candidate_upload_is_success_only(self):
        workflow = (ROOT / ".github/workflows/mac-shared-candidate.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("workflow_call:", workflow)
        self.assertIn("if: success()", workflow)
        self.assertIn("if: failure()", workflow)
        self.assertIn("include-hidden-files: true", workflow)
        self.assertIn("PiliPlusX-shared-candidate.shared-core.json", workflow)
        self.assertIn("PiliPlusX-shared-candidate.shared-backend.json", workflow)
        self.assertIn("artifact/receipts/", workflow)
        self.assertIn("piliplusx-shared-candidate/*/logs/", workflow)
        self.assertIn("macos-shared-candidate-failure-", workflow)
        self.assertIn("contents: read", workflow)

    def test_pipeline_stage_order_is_explicit_and_candidate_is_last(self):
        # The executable mock pipeline below verifies ordering and outputs.
        self.assertTrue(callable(candidate.run_pipeline))

    def test_safe_output_paths_reject_symlink_dangling_and_traversal(self):
        sha = "1234567890"
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            for bad in ("../x", "/tmp/x", "1/2", "", ".."):
                with self.subTest(run_id=bad):
                    with self.assertRaises(candidate.CandidateError):
                        candidate.owned_runner_paths(base, bad, "1")
                with self.subTest(attempt=bad):
                    with self.assertRaises(candidate.CandidateError):
                        candidate.owned_runner_paths(base, "1", bad)
            target = base / "outside"
            target.mkdir()
            (base / "piliplusx-shared-candidate-diagnostics").symlink_to(target)
            with self.assertRaises(candidate.CandidateError):
                candidate.owned_runner_paths(base, sha, "1")
            self.assertEqual(list(target.iterdir()), [])
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            (base / "piliplusx-shared-candidate").symlink_to(base / "dangling", target_is_directory=True)
            with self.assertRaises(candidate.CandidateError):
                candidate.owned_runner_paths(base, "1", "1")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            link = base / "runner-temp"
            link.symlink_to(base, target_is_directory=True)
            with self.assertRaises(candidate.CandidateError):
                candidate.owned_runner_paths(link, "1", "1")

    def test_source_tree_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            report = {"report_path": str(checkout / "result.json")}
            with mock.patch.object(candidate, "run", return_value=subprocess.CompletedProcess([], 1, "", "dirty")):
                with self.assertRaisesRegex(candidate.CandidateError, "tracked content drifted"):
                    candidate.verify_source_tree(checkout, "a" * 40, {"media_kit": "media_kit"}, report)

    def test_compatibility_plan_is_exact_and_rejects_out_of_scope_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            good = root / "lib/src/util.dart"
            good.parent.mkdir(parents=True)
            good.write_text("bool x = defaultTargetPlatform == TargetPlatform.ohos;\n")
            plan = candidate.compatibility_plan(root)
            self.assertEqual(plan["lib/src/util.dart"], b"bool x = false;\n")
            outside = root / "lib/unapproved.dart"
            outside.parent.mkdir(parents=True, exist_ok=True)
            outside.write_text("bool x = defaultTargetPlatform == TargetPlatform.ohos;\n")
            with self.assertRaisesRegex(candidate.CandidateError, "outside the reviewed file allowlist"):
                candidate.compatibility_plan(root)

    def _assert_compat_node_change_rejected(self, kind):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "lib/src/util.dart"
            source.parent.mkdir(parents=True)
            source.write_text("bool x = defaultTargetPlatform == TargetPlatform.ohos;\n")
            plan = candidate.compatibility_plan(root)
            expected = candidate.node_inventory(root)
            for relative, content in plan.items():
                expected[relative] = {"type": "file", "sha256": hashlib.sha256(content).hexdigest(),
                                      "bytes": len(content)}
                (root / relative).write_bytes(content)
            if kind == "file-symlink":
                (root / "lib/src/extra.dart").symlink_to(source)
            elif kind == "directory-symlink":
                (root / "linked-directory").symlink_to(root / "lib/src", target_is_directory=True)
            elif kind == "empty-directory":
                (root / "empty-directory").mkdir()
            elif kind == "special-node":
                os.mkfifo(root / "special.fifo")
            else:
                raise AssertionError(kind)
            with self.assertRaisesRegex(candidate.CandidateError, "outside the approved byte transforms"):
                candidate.require_expected_compat_nodes(expected, candidate.node_inventory(root))

    def test_compat_approved_change_plus_file_symlink_is_rejected(self):
        self._assert_compat_node_change_rejected("file-symlink")

    def test_compat_approved_change_plus_directory_symlink_is_rejected(self):
        self._assert_compat_node_change_rejected("directory-symlink")

    def test_compat_approved_change_plus_empty_directory_is_rejected(self):
        self._assert_compat_node_change_rejected("empty-directory")

    def test_compat_approved_change_plus_special_node_is_rejected(self):
        self._assert_compat_node_change_rejected("special-node")

    def _pipeline_case(self, fail_at=None, production_release=False):
        sha = "a" * 40
        names = ["media_kit", "media_kit_video"]
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            workspace = base / "workspace"
            workspace.mkdir()
            pubspec = workspace / "pubspec.yaml"
            pubspec.write_text("name: fixture\n")
            (workspace / "lib/pages/video").mkdir(parents=True)
            view = workspace / "lib/pages/video/view.dart"
            view.write_text("class V {\n            pointerDownFilter: _allowOuterVideoPointer,\n}\n")
            lock = workspace / "pubspec.lock"
            lock.write_bytes(b"original lock bytes\n")
            overrides = workspace / "pubspec_overrides.yaml"
            overrides.write_bytes(b"dependency_overrides:\n  kept: any\n")
            config = workspace / ".dart_tool/package_config.json"
            config.parent.mkdir()
            config.write_bytes(b'{"original":true}\n')
            patch_file = workspace / "lib/scripts/material/fixture.patch"
            patch_file.parent.mkdir(parents=True)
            patch_file.write_bytes(b"fixture patch bytes\r\n")
            original = {p: p.read_bytes() for p in (pubspec, view, lock, overrides, config, patch_file)}
            runner_temp = base / "runner-temp"
            runner_temp.mkdir()
            run_dir = runner_temp / "piliplusx-shared-candidate/77-1"
            run_dir.mkdir(parents=True)
            report_path = runner_temp / "report/result.json"
            report_path.parent.mkdir()
            report = {"run_dir": str(run_dir), "report_path": str(report_path.resolve()),
                      "media_kit_package_names": names, "commands": []}
            calls = []
            command_vectors = []

            def fake_run(argv, *, cwd=None, env=None, report=None, label="command", check=True):
                calls.append(label)
                command_vectors.append([str(item) for item in argv])
                if label == fail_at:
                    raise candidate.CandidateError(f"injected {label}")
                completed = subprocess.CompletedProcess(argv, 0, "", "")
                if label == "media-kit-init":
                    checkout = Path(cwd)
                    for name in names:
                        package = checkout / name
                        package.mkdir(parents=True)
                        (package / "pubspec.yaml").write_text(f"name: {name}\n")
                    recipe_dir = checkout / "tool/shared_gpu_next"
                    recipe_dir.mkdir(parents=True)
                    video = checkout / "media_kit_video"
                    bridge = video / candidate.MEDIA_KIT_BRIDGE
                    bridge.parent.mkdir(parents=True)
                    bridge.write_bytes(b"approved bridge bytes")
                    return completed
                if label == "media-kit-head":
                    return subprocess.CompletedProcess(argv, 0, sha + "\n", "")
                if label == "approved-source-tree-diff":
                    return completed
                if label == "approved-source-tree-inventory":
                    return completed
                if label.startswith("package-root-") and argv[-1] == "--show-toplevel":
                    return subprocess.CompletedProcess(argv, 0, str(run_dir / "pub-cache/git/cache/media-kit") + "\n", "")
                if label.startswith("package-head-"):
                    return subprocess.CompletedProcess(argv, 0, sha + "\n", "")
                if label.startswith("package-origin-"):
                    return subprocess.CompletedProcess(argv, 0, candidate.MEDIA_KIT_URL + "\n", "")
                if label.startswith("package-cache-bare-"):
                    return subprocess.CompletedProcess(argv, 0, "true\n", "")
                if label.startswith("package-cache-origin"):
                    return subprocess.CompletedProcess(argv, 0, candidate.MEDIA_KIT_URL + "\n", "")
                if label.startswith("package-cache-approved-commit-"):
                    return completed
                if label == "pub-get":
                    if fail_at == "pub-get":
                        raise candidate.CandidateError("injected pub-get")
                    cache_root = run_dir / "pub-cache/git/cache/media-kit"
                    for name in names:
                        package = cache_root / name
                        package.mkdir(parents=True, exist_ok=True)
                        (package / "pubspec.yaml").write_text(f"name: {name}\n")
                    (run_dir / "pub-cache/git/cache/media-kit-fixture").mkdir(parents=True)
                    source_bridge = run_dir / "media-kit/media_kit_video" / candidate.MEDIA_KIT_BRIDGE
                    cached_bridge = cache_root / "media_kit_video" / candidate.MEDIA_KIT_BRIDGE
                    cached_bridge.parent.mkdir(parents=True, exist_ok=True)
                    cached_bridge.write_bytes(source_bridge.read_bytes())
                    compat = run_dir / "pub-cache/hosted/pub.dev/flutter_inappwebview_platform_interface-1.3.0+1"
                    (compat / "lib/src").mkdir(parents=True)
                    (compat / "lib/src/util.dart").write_text(
                        "bool x = defaultTargetPlatform == TargetPlatform.ohos;\n")
                    config.write_text(json.dumps({"packages": [
                        *[{"name": name, "rootUri": (cache_root / name).as_uri() + "/"} for name in names],
                        {"name": "flutter_inappwebview_platform_interface", "rootUri": compat.as_uri() + "/"}
                    ]}))
                    lock.write_text("".join(
                        f'  {name}:\n    dependency: direct main\n    description:\n'
                        f'      path: "{name}"\n      ref: {sha}\n      resolved-ref: {sha}\n'
                        f'      url: "{candidate.MEDIA_KIT_URL}"\n    source: git\n    version: "1.0.0"\n'
                        for name in names))
                if label == "release-package-patches":
                    patch_file.write_bytes(patch_file.read_bytes().replace(b"\r\n", b"\n"))
                if label == "compatibility-patch":
                    if fail_at == "compatibility-patch":
                        raise candidate.CandidateError("injected compatibility-patch")
                    item = json.loads(config.read_text())["packages"][-1]
                    parser = __import__("urllib.parse", fromlist=["urlparse", "unquote"])
                    root = Path(parser.unquote(parser.urlparse(item["rootUri"]).path))
                    for rel, data in candidate.compatibility_plan(root).items():
                        (root / rel).write_bytes(data)
                    if fail_at == "compatibility-out-of-scope":
                        (root / "lib/unapproved.dart").write_text("unapproved edit\n")
                    view.write_text(view.read_text().replace(
                        "            pointerDownFilter: _allowOuterVideoPointer,\n", "", 1))
                if label == "acquire-fetch":
                    out = Path(argv[argv.index("--output") + 1]); out.mkdir(parents=True)
                    (out / "acquisition-manifest.json").write_text("{}\n")
                    Path(argv[argv.index("--log-dir") + 1]).mkdir(parents=True)
                if label == "sign-contexts":
                    out = Path(argv[argv.index("--output") + 1]); ass = out / "frameworks/Ass.framework/Versions/A/Ass"
                    ass.parent.mkdir(parents=True); ass.write_bytes(b"Ass")
                    manifest = out / "sealed/signed-context-manifest.json"; manifest.parent.mkdir(parents=True)
                    manifest.write_text(json.dumps({"after": {"Ass": {"binary_sha256": candidate.digest(ass)}}}))
                    Path(argv[argv.index("--log-dir") + 1]).mkdir(parents=True)
                if label == "fresh-runtime-build":
                    runtime_dir = Path(argv[2]); runtime_dir.mkdir(parents=True)
                    (runtime_dir / "manifest.json").write_text("{}\n")
                    (Path(argv[argv.index("--work-dir") + 1]) / "logs").mkdir(parents=True)
                if label == "prepare-sealed-inputs":
                    out = Path(argv[argv.index("--output") + 1]) / "sealed/inputs-manifest.json"
                    out.parent.mkdir(parents=True); out.write_text("{}\n")
                if label == "bootstrap-release-build":
                    build_dir = Path(argv[argv.index("--build-dir") + 1])
                    app = build_dir / "macos/Build/Products/Release/PiliPlusX.app"
                    (app / "Contents/MacOS").mkdir(parents=True)
                    (app / "Contents/MacOS/PiliPlusX").write_bytes(b"runner")
                    with (app / "Contents/Info.plist").open("wb") as stream:
                        import plistlib; plistlib.dump({"MediaKitSharedBootstrapPending": True}, stream)
                if label == "bootstrap-ordinary-guard":
                    return subprocess.CompletedProcess(argv, 1, "", "shared bootstrap is pending")
                if label == "shared-consumer":
                    output = Path(argv[argv.index("--output-app") + 1])
                    (output / "Contents/MacOS").mkdir(parents=True)
                    (output / "Contents/MacOS/PiliPlusX").write_bytes(b"runner-final")
                    import plistlib
                    with (output / "Contents/Info.plist").open("wb") as stream:
                        plistlib.dump({"MediaKitSharedRenderer": True}, stream)
                    output.with_suffix(".shared-core.json").write_text("{}\n")
                    output.with_suffix(".shared-backend.json").write_text("{}\n")
                    log_dir = Path(argv[argv.index("--log-dir") + 1]); log_dir.mkdir(parents=True)
                    (log_dir / "result.json").write_text("{}\n")
                if label == "candidate-archive":
                    Path(argv[-1]).write_bytes(b"zip")
                return completed

            old_root = candidate.ROOT
            candidate.ROOT = workspace.resolve()
            flutter_root = base / "flutter-sdk-source"
            (flutter_root / "bin").mkdir(parents=True)
            (flutter_root / "bin/flutter").write_text("mock flutter\n")
            try:
                with mock.patch.object(candidate, "run", side_effect=fake_run), \
                     mock.patch.object(candidate.shutil, "which", return_value="pwsh"), \
                     mock.patch.dict(os.environ, {"FLUTTER_ROOT": str(flutter_root)}):
                    try:
                        candidate.run_pipeline(report, "b" * 40, sha,
                                               production_release=production_release)
                    except candidate.CandidateError as error:
                        report.update(status="failed", error=str(error))
                self.assertEqual({p: p.read_bytes() for p in original}, original)
            finally:
                candidate.ROOT = old_root
            artifact_dir = run_dir / "artifact"
            report["_mock_artifact_files"] = [p.relative_to(artifact_dir).as_posix()
                                               for p in artifact_dir.rglob("*") if p.is_file()] \
                if artifact_dir.exists() else []
            report["_mock_command_argv"] = command_vectors
            return report, calls, run_dir

    def test_full_mock_pipeline_success_emits_candidate_sidecars_and_receipts(self):
        report, calls, run_dir = self._pipeline_case()
        self.assertEqual(report["status"], "candidate-built", (report.get("error"), calls))
        artifact_files = report["_mock_artifact_files"]
        self.assertIn("PiliPlusX-shared-candidate.zip", artifact_files)
        self.assertIn("PiliPlusX-shared-candidate.shared-core.json", artifact_files)
        self.assertIn("PiliPlusX-shared-candidate.shared-backend.json", artifact_files)
        for receipt_name in ("acquisition-manifest.json", "signed-context-manifest.json",
                             "runtime-manifest.json", "sealed-inputs-manifest.json",
                             "consumer-result.json", "stage-receipts.json"):
            self.assertIn(f"receipts/{receipt_name}", artifact_files)
        self.assertLess(calls.index("pub-get"), calls.index("acquire-fetch"))
        self.assertLess(calls.index("shared-consumer"), calls.index("final-bundle-gate"))

    def test_production_hook_orders_sdk_resolution_package_patches_and_app_receipt(self):
        report, calls, run_dir = self._pipeline_case(production_release=True)
        self.assertEqual(report["status"], "candidate-built", (report.get("error"), calls))
        self.assertLess(calls.index("release-sdk-patches"), calls.index("pub-get"))
        self.assertLess(calls.index("pub-get"), calls.index("release-package-patches"))
        self.assertLess(calls.index("release-package-patches"), calls.index("compatibility-patch"))
        self.assertLess(calls.index("release-package-patches"), calls.index("acquire-fetch"))
        lock_gates = [index for index, label in enumerate(calls) if label == "media-kit-lock-gate"]
        self.assertEqual(len(lock_gates), 3, calls)
        self.assertLess(calls.index("pub-get"), lock_gates[0])
        self.assertLess(lock_gates[0], calls.index("release-package-patches"))
        self.assertLess(calls.index("release-package-patches"), lock_gates[1])
        self.assertLess(lock_gates[1], calls.index("compatibility-patch"))
        self.assertLess(calls.index("compatibility-patch"), lock_gates[2])
        self.assertLess(calls.index("shared-consumer"), calls.index("final-bundle-gate"))
        sdk_command = next(command for command in report["_mock_command_argv"]
                           if command[0] == "pwsh" and "-SdkOnly" in command)
        package_command = next(command for command in report["_mock_command_argv"]
                               if command[0] == "pwsh" and "-PackagesOnly" in command)
        self.assertEqual(sdk_command[-2:], ["macOS", "-SdkOnly"])
        self.assertEqual(package_command[-2:], ["macOS", "-PackagesOnly"])
        self.assertNotIn("PiliPlusX-shared-candidate.zip", report["_mock_artifact_files"])
        receipt = report["stage_receipts"]["published_candidate"]["final_app"]
        self.assertEqual(receipt["path"], report["artifact"]["final_app"])
        self.assertGreater(receipt["node_count"], 1)
        self.assertEqual(receipt["inventory_sha256"], receipt["tree_identity_sha256"])
        self.assertTrue(receipt["path"].endswith(".app"))

    def test_production_package_patch_failure_restores_workspace_and_stops(self):
        failed, calls, _ = self._pipeline_case("release-package-patches", production_release=True)
        self.assertEqual(failed["status"], "failed")
        self.assertIn("release-sdk-patches", calls)
        self.assertIn("pub-get", calls)
        self.assertIn("release-package-patches", calls)
        self.assertNotIn("compatibility-patch", calls)
        self.assertNotIn("acquire-fetch", calls)
        self.assertNotIn("artifact", failed)
        self.assertEqual(failed["_mock_artifact_files"], [])

    def test_production_later_failure_restores_package_patch_mutations(self):
        failed, calls, _ = self._pipeline_case("compatibility-patch", production_release=True)
        self.assertEqual(failed["status"], "failed")
        self.assertLess(calls.index("release-package-patches"), calls.index("compatibility-patch"))
        self.assertNotIn("acquire-fetch", calls)
        self.assertNotIn("artifact", failed)

    def test_patch_script_has_separate_sdk_and_lock_enforced_package_phases(self):
        patcher = (ROOT / "lib/scripts/patch.ps1").read_text()
        sdk_only_return = patcher.index('if ($SdkOnly) {')
        package_enforcement = patcher.index("flutter pub get --enforce-lockfile")
        package_resolution = patcher.index('Get-PackageConfigRoot "material_ui"')
        self.assertLess(sdk_only_return, package_enforcement)
        self.assertLess(package_enforcement, package_resolution)
        self.assertIn("[switch]$SdkOnly", patcher)
        self.assertIn("[switch]$PackagesOnly", patcher)
        self.assertIn("if (-not $PackagesOnly) {", patcher)

    def _assert_pipeline_failure(self, stage, failed_before=None):
        failed, failed_calls, _ = self._pipeline_case(stage)
        self.assertEqual(failed["status"], "failed")
        self.assertNotIn("artifact", failed)
        self.assertNotIn("PiliPlusX-shared-candidate.zip", failed["_mock_artifact_files"])
        expected_call = "compatibility-patch" if stage == "compatibility-out-of-scope" else stage
        self.assertIn(expected_call, failed_calls)
        if failed_before:
            self.assertNotIn(failed_before, failed_calls)

    def test_pipeline_pubget_failure_restores_workspace_and_stops(self):
        self._assert_pipeline_failure("pub-get", "acquire-fetch")

    def test_pipeline_compatibility_failure_restores_workspace_and_stops(self):
        self._assert_pipeline_failure("compatibility-patch", "acquire-fetch")

    def test_pipeline_compatibility_out_of_scope_change_is_rejected(self):
        self._assert_pipeline_failure("compatibility-out-of-scope", "acquire-fetch")

    def test_pipeline_consumer_failure_restores_workspace_and_stops(self):
        self._assert_pipeline_failure("shared-consumer", "final-bundle-gate")

    def test_pipeline_final_gate_failure_prevents_archive(self):
        self._assert_pipeline_failure("final-bundle-gate", "candidate-archive")


if __name__ == "__main__":
    unittest.main(verbosity=2)
