"""Actual locked Dart/YAML parser semantics; no regex or synthetic parser fallback."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import prepare_android_variant as variant


class ManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = os.environ.get('GITHUB_ACTIONS') == 'true' or os.environ.get('CI', '').lower() == 'true'
        cls.parser = ROOT / 'android/tool/parse_routing_manifest.dart'
        cls.sdk = Path(os.environ.get('FLUTTER_ROOT', str(ROOT.parent / '.runtime/flutter'))).resolve()
        cls.cache = Path(os.environ.get('PUB_CACHE', str(ROOT.parent / '.runtime/pub-cache'))).resolve()
        cls.dart = cls.sdk / 'bin/cache/dart-sdk/bin/dart'
        cls.config = cls.sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
        cls.proof = {'scope': 'manifest-parser-tests', 'hostedAcceptance': False,
                     'mode': 'bootstrap-bound-ci' if cls.ci else 'local-candidate',
                     'status': 'running', 'commands': [], 'checks': []}
        cls.proof_path = None
        if cls.ci:
            for name in ('FLUTTER_ROOT', 'PUB_CACHE', 'ROUTING_BOOTSTRAP_RECEIPT',
                         'ROUTING_RESULTS', 'RUNNER_TEMP', 'EXPECTED_APP_SHA', 'EXPECTED_MEDIA_KIT_SHA'):
                if not os.environ.get(name):
                    raise RuntimeError('CI manifest tests require ' + name)
            results = Path(os.environ['ROUTING_RESULTS']).resolve(strict=True)
            temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
            if results == temporary or not results.is_relative_to(temporary) or results.is_relative_to(ROOT):
                raise RuntimeError('CI manifest proof must use private runner results')
            cls.proof_path = results / 'manifest-parser-tests.json'
            cls.receipt_path = Path(os.environ['ROUTING_BOOTSTRAP_RECEIPT'])
            if cls.receipt_path.is_symlink() or cls.receipt_path.resolve(strict=True) != results / 'bootstrap.json':
                raise RuntimeError('CI manifest tests require the exact private bootstrap receipt')
            cls.bootstrap_bytes = cls.receipt_path.read_bytes()
            cls.bootstrap = json.loads(cls.bootstrap_bytes)
            vector = cls.bootstrap.get('vector', {})
            cls.app_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
            media = ROOT.parent / 'media-kit'
            cls.media_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=media, text=True).strip()
            if (cls.bootstrap.get('scope') != 'routing-source-bootstrap'
                    or cls.bootstrap.get('status') != 'prepared-source-only'
                    or cls.bootstrap.get('platform') != 'android'
                    or cls.app_head != os.environ['EXPECTED_APP_SHA'] or vector.get('app') != cls.app_head
                    or cls.media_head != os.environ['EXPECTED_MEDIA_KIT_SHA'] or vector.get('media-kit') != cls.media_head
                    or cls.bootstrap.get('afterVector') != vector):
                raise RuntimeError('CI manifest bootstrap/source vector mismatch')
            private = results.parent
            if (cls.sdk != Path(cls.bootstrap['flutterRoot']).resolve(strict=True)
                    or cls.cache != Path(cls.bootstrap['pubCache']).resolve(strict=True)
                    or not cls.sdk.is_relative_to(private) or not cls.cache.is_relative_to(private)
                    or cls.sdk == private or cls.cache == private):
                raise RuntimeError('CI manifest SDK/cache must match the bootstrap private roots')
            cls.expected_parser = subprocess.check_output(
                ['git', 'cat-file', 'blob', cls.app_head + ':android/tool/parse_routing_manifest.dart'], cwd=ROOT)
            for root, key in ((ROOT, 'appTree'), (media, 'media-kitTree')):
                tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root, text=True).strip()
                if tree != vector.get(key):
                    raise RuntimeError('CI manifest bootstrap/source tree mismatch')
            helper_blob = subprocess.check_output(
                ['git', 'cat-file', 'blob', cls.app_head + ':scripts/prepare_android_variant.py'], cwd=ROOT)
            if helper_blob != Path(variant.__file__).read_bytes():
                raise RuntimeError('CI manifest identity helper differs from App HEAD')
            cls.proof.update(vector=vector, bootstrapSha256=hashlib.sha256(cls.bootstrap_bytes).hexdigest())
        else:
            # Local worktree candidates are useful semantic evidence, not a clean
            # committed source vector or an executed hosted bootstrap.
            cls.expected_parser = cls.parser.read_bytes()
            cls.bootstrap = {'sdkCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=cls.sdk, text=True).strip(),
                             'flutterToolsPackages': variant.package_roots(cls.config, [cls.sdk, cls.cache])}
            if os.environ.get('ROUTING_RESULTS'):
                results = Path(os.environ['ROUTING_RESULTS']).resolve(strict=True)
                if results.is_relative_to(ROOT):
                    raise RuntimeError('Local parser proof must stay outside App sources')
                cls.proof_path = results / 'manifest-parser-tests.json'
        if not cls.dart.is_file() or not cls.config.is_file():
            raise RuntimeError('real Flutter tools SDK/package_config required for YAML security tests')
        cls.addClassCleanup(cls.save_proof)
        cls.initial_identity = cls.tool_identity()
        cls.proof['identity'] = cls.initial_identity

    @classmethod
    def save_proof(cls):
        if cls.proof_path:
            cls.proof_path.write_text(json.dumps(cls.proof, indent=2) + '\n')

    @classmethod
    def tool_identity(cls):
        if cls.ci:
            if cls.receipt_path.read_bytes() != cls.bootstrap_bytes:
                raise RuntimeError('CI bootstrap receipt changed during parser tests')
            for root, expected in ((ROOT, cls.app_head), (ROOT.parent / 'media-kit', cls.media_head)):
                if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip() != expected:
                    raise RuntimeError('CI source HEAD changed during parser tests')
            if (Path(os.environ['FLUTTER_ROOT']).resolve() != cls.sdk
                    or Path(os.environ['PUB_CACHE']).resolve() != cls.cache):
                raise RuntimeError('CI SDK/cache environment changed during parser tests')
        return variant.manifest_identity(ROOT, {'android/tool/parse_routing_manifest.dart': cls.expected_parser},
                                         cls.sdk, cls.cache, cls.parser, cls.proof, cls.bootstrap)

    def setUp(self):
        self.assertEqual(self.tool_identity(), self.initial_identity, 'parser tool identity changed before test')

    def tearDown(self):
        try:
            self.assertEqual(self.tool_identity(), self.initial_identity, 'parser tool identity changed after test')
            self.proof['checks'].append({'test': self.id(), 'identityUnchanged': True})
            self.proof['status'] = 'identity-stable-semantic-tests'
        except Exception:
            self.proof['status'] = 'failed'
            raise
        finally:
            self.save_proof()

    def run_parser(self, text):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / 'pubspec.yaml'
            manifest.write_text(text)
            result = subprocess.run([str(self.dart),'--packages='+str(self.config),str(self.parser),'--manifest',str(manifest)],capture_output=True,text=True)
            return result, json.loads(result.stdout) if result.returncode == 0 else None

    def test_tool_compiles_against_real_tools_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            result=subprocess.run([str(self.dart),'compile','kernel','--packages='+str(self.config),str(self.parser),'-o',str(Path(directory)/'parser.dill')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr+result.stdout)

    def test_normal_assets_maps_anchors_fonts_shaders_deferred_decode(self):
        result,data=self.run_parser('''name: fixture
version: 1.0.0
asset: &resource assets/known.json
flutter:
  assets:
    - *resource
    - path: assets/folder/
      flavors: [pink]
      platforms: [linux, macos]
  shaders: [assets/known.frag]
  fonts:
    - family: Known
      fonts:
        - asset: assets/known.ttf
          weight: 400
          style: normal
  deferred-components:
    - name: lazy
      libraries: [package:fixture/lazy.dart]
      assets: [assets/lazy.json]
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual([entry['kind'] for entry in data['inputs']],['asset','asset','asset','shader','font'])
        self.assertEqual(data['inputs'][1]['directory'],True)

    def test_decoded_escaped_generated_paths_rejected_by_prebuild_contract(self):
        for value in ('"\\u0062uild/generated.json"','"%62uild/generated.json"','assets/../build/generated.json'):
            with self.subTest(value=value):
                result,data=self.run_parser('flutter:\n  assets: ['+value+']\n')
                self.assertEqual(result.returncode,0,result.stderr)
                with self.assertRaisesRegex(variant.GateError,'declared input overlaps'):
                    variant.check_generated_declarations({},data['inputs'])

    def test_absolute_uri_encoded_absolute_query_fragment_rejected(self):
        for value in ('/tmp/unreviewed','file:///tmp/unreviewed','https://example.invalid/a','%2Ftmp/file','assets/a?b','assets/a#b','"C:\\\\tmp\\\\file"'):
            with self.subTest(value=value):
                result,_=self.run_parser('flutter:\n  assets: ['+value+']\n')
                self.assertNotEqual(result.returncode,0,result.stdout)

    def test_invalid_yaml_documents_tags_types_keys_duplicates_aliases_rejected(self):
        cases=('flutter: {}\n---\nflutter: {}\n','flutter:\n  assets: !Foo [assets/a]\n','flutter: {assets: 3}\n','flutter: {assets: [3]}\n','? [complex, key]\n: bad\n','flutter: {}\nflutter: {}\n','a: &a [*a]\n','flutter: {assets: [{path: assets/a, transformers: []}]}\n','flutter: {fonts: [{family: X, fonts: [{asset: assets/a, weight: bad}]}]}\n')
        for text in cases:
            with self.subTest(text=text):
                result,_=self.run_parser(text)
                self.assertNotEqual(result.returncode,0,result.stdout)

    def test_shared_darwin_uses_parsed_boolean_and_lock_yaml_version(self):
        result,data=self.run_parser('name: plugin\nversion: 1.2.3\nflutter:\n  plugin:\n    platforms:\n      ios: {sharedDarwinSource: true}\n      macos: {sharedDarwinSource: false}\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(data['pluginPlatforms'],{'ios':{'sharedDarwinSource':True},'macos':{'sharedDarwinSource':False}})
        result,data=self.run_parser('packages:\n  yaml: {version: "3.1.3"}\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(data['lockYamlVersion'],'3.1.3')

    def test_real_current_app_resource_declarations_are_tracked(self):
        result,data=self.run_parser((ROOT/'pubspec.yaml').read_text())
        self.assertEqual(result.returncode,0,result.stderr)
        files={name:(ROOT/name).read_bytes() for name in subprocess.check_output(['git','ls-files'],cwd=ROOT,text=True).splitlines() if (ROOT/name).is_file()}
        variant.check_generated_declarations(files,data['inputs'])


if __name__=='__main__':unittest.main()
