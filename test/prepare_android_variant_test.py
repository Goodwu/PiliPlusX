"""Byte-copy and locked-root contracts; fake pub resolution is explicitly synthetic."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import prepare_android_variant as variant
from verify_routing_sources import PACKAGES


class VariantTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.media = self.root / 'media-kit'
        for relative in PACKAGES.values():
            (self.media / relative).mkdir(parents=True, exist_ok=True)
        self.sdk = self.root / 'sdk'
        (self.sdk / 'bin').mkdir(parents=True)
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        for name, (old, _, count) in variant.PINK.items():
            file = self.source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes((old + b'\n') * count)
        (self.source/'pubspec.yaml').write_text('name: piliplus\nflutter:\n  assets:\n    - assets/\n    - path: assets/shaders/\n  shaders:\n    - assets/shaders/known.frag\n  fonts:\n    - family: Fixture\n      fonts:\n        - asset: assets/fonts/known.ttf\n')
        for name,payload in {'assets/known.json':b'{}','assets/shaders/known.frag':b'void main(){}','assets/fonts/known.ttf':b'synthetic-font','android/app/src/main/res/values/known.xml':b'<resources/>'}.items():
            file=self.source/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(payload)
        (self.source / 'pubspec.lock').write_text('packages:\n'+''.join(f'  {name}:\n    description:\n      path: \"../media-kit/{path}\"\n      relative: true\n    source: path\n    version: \"1.0.0\"\n' for name,path in PACKAGES.items()))
        (self.source / 'pubspec_overrides.yaml').write_bytes(b'synthetic relative overrides\n')
        for argv in (['git','init'],['git','config','user.name','Fixture'],['git','config','user.email','fixture@example.invalid'],['git','add','.'],['git','commit','-m','synthetic fixture']):
            subprocess.run(argv, cwd=self.source, capture_output=True, check=True)
        self.app_sha = subprocess.check_output(['git','rev-parse','HEAD'], cwd=self.source, text=True).strip()
        (self.media/'README').write_bytes(b'synthetic native source tree')
        for argv in (['git','init'],['git','config','user.name','Fixture'],['git','config','user.email','fixture@example.invalid'],['git','add','.'],['git','commit','-m','synthetic media fixture']):
            subprocess.run(argv,cwd=self.media,capture_output=True,check=True)
        self.media_sha = subprocess.check_output(['git','rev-parse','HEAD'],cwd=self.media,text=True).strip()
        self.target = self.root / 'private/pink/app'
        self.receipt = {}
        self.bootstrap = {'status':'prepared-source-only','vector':{'app':self.app_sha,'media-kit':self.media_sha},'flutterRoot':str(self.sdk),'pubCache':str(self.cache),'sdkCommit':'synthetic','flutterToolsPackages':{}}
        self.base_roots = {'piliplus': str(self.source.resolve()), **{name:str((self.media/path).resolve()) for name,path in PACKAGES.items()}}
        self.write_config(self.source, self.base_roots)
        self.before = {p.name:p.read_bytes() for p in self.source.iterdir() if p.is_file()}
        self.real_command = variant.command
        self.pub_calls = []
        # This fixture intentionally has no real SDK. Product parsing has no
        # fallback; real YAML semantics are exercised by its standalone suite.
        identity=patch.object(variant,'manifest_identity',return_value={'synthetic':True})
        identity.start();self.addCleanup(identity.stop)
        context=patch.object(variant,'input_context',side_effect=self.context)
        context.start();self.addCleanup(context.stop)

    def context(self, root, media, sdk, cache, parser, receipt):
        return {'packageRoots':variant.roots(root,media,sdk,cache),'resources':[],
                'allowedLinks':getattr(self,'allowed_links',{}),'packageManifestHashes':{'piliplus':'synthetic-unchanged'}}

    def write_config(self, root, mapping):
        file=root/'.dart_tool/package_config.json'
        file.parent.mkdir(parents=True,exist_ok=True)
        file.write_text(json.dumps({'configVersion':2,'packages':[{'name':name,'rootUri':Path(path).as_uri(),'packageUri':'lib/'} for name,path in mapping.items()]}))

    def command(self, argv, cwd, receipt):
        if argv[0] == str(self.sdk/'bin/flutter'):
            self.pub_calls.append(argv)
            roots=dict(self.base_roots);roots['piliplus']=str(self.target.resolve())
            self.write_config(self.target, roots)
            for name,permit in getattr(self,'allowed_links',{}).items():
                link=self.target/name;link.parent.mkdir(parents=True,exist_ok=True);link.symlink_to(permit['canonicalTarget'],target_is_directory=True)
            return b'synthetic offline resolution\n'
        return self.real_command(argv,cwd,receipt)

    def prepare(self, flavor='pink', hdr=None):
        with patch.dict(os.environ, RUNNER_TEMP=str(self.root), FLUTTER_ROOT=str(self.sdk), PUB_CACHE=str(self.cache)),patch.object(variant,'command',side_effect=self.command),patch.object(variant,'verify_hdr',return_value=hdr or []):
            variant.prepare(self.source,self.media,self.target,self.app_sha,self.media_sha,flavor,self.receipt,self.bootstrap)
        self.prebuild()

    def prebuild(self):
        with patch.object(variant,'verify_hdr',return_value=[]):
            variant.finalize(self.source,self.media,self.target,self.app_sha,self.media_sha,self.receipt['flavor'],self.receipt,prebuild=True)

    def finish(self):
        with patch.object(variant,'verify_hdr',return_value=[]):
            variant.finalize(self.source,self.media,self.target,self.app_sha,self.media_sha,self.receipt['flavor'],self.receipt)

    def test_pink_copy_transforms_exact_occurrences_preserving_original(self):
        self.prepare()
        self.assertEqual(self.receipt['status'],'prepared')
        self.assertEqual(self.pub_calls[0][1:],['pub','get','--offline','--enforce-lockfile'])
        for name,(old,new,count) in variant.PINK.items():
            original=(self.source/name).read_bytes()
            self.assertEqual(original.count(old),count)
            self.assertEqual((self.target/name).read_bytes(),original.replace(old,new))
        self.finish();self.assertEqual(self.receipt['status'],'finalized')

    def test_regular_variant_preserves_every_tracked_byte(self):
        self.prepare('android')
        self.assertEqual(self.receipt['beforeHashes'],self.receipt['afterHashes'])
        self.finish()

    def test_transform_contract_matches_real_current_source_counts(self):
        root=Path(__file__).resolve().parents[1]
        files={name:((root/name).read_bytes(),'100644') for name in variant.PINK}
        expected=variant.expected_variant(files,'pink')
        self.assertEqual(set(expected),set(variant.PINK))

    def test_unknown_transform_count_is_rejected(self):
        files={name:(old*count,'100644') for name,(old,_,count) in variant.PINK.items()}
        files['lib/utils/update.dart']=(b'unknown source','100644')
        with self.assertRaisesRegex(variant.GateError,'occurrence count'):
            variant.expected_variant(files,'pink')

    def test_dirty_original_is_not_overwritten(self):
        file=self.source/'lib/utils/update.dart';file.write_bytes(b'uncommitted preserved')
        with self.assertRaisesRegex(variant.GateError,'variant command failed'):
            self.prepare()
        self.assertEqual(file.read_bytes(),b'uncommitted preserved')
        self.assertFalse(self.target.exists())

    def test_existing_variant_output_is_not_cleaned(self):
        self.target.mkdir(parents=True);saved=self.target/'preserved';saved.write_bytes(b'keep')
        with self.assertRaisesRegex(variant.GateError,'fresh private'):
            self.prepare()
        self.assertEqual(saved.read_bytes(),b'keep')

    def test_wrong_bootstrap_vector_is_rejected(self):
        self.bootstrap['vector']['app']='9'*40
        with self.assertRaisesRegex(variant.GateError,'prepared exact'):
            self.prepare()

    def test_shared_SDK_or_cache_cannot_be_substituted(self):
        self.bootstrap['pubCache']=str(self.root/'other-cache')
        with self.assertRaisesRegex(variant.GateError,'private SDK/cache'):
            self.prepare()

    def test_HDR_channel_failure_prevents_prepared_variant(self):
        with self.assertRaisesRegex(variant.GateError,'HDR channel'):
            self.prepare(hdr=['channel changed'])

    def test_external_package_root_must_remain_identical(self):
        original=self.command
        def changed(argv,cwd,receipt):
            result=original(argv,cwd,receipt)
            if argv[0]==str(self.sdk/'bin/flutter'):
                config=json.loads((self.target/'.dart_tool/package_config.json').read_text())
                config['packages'].append({'name':'extra','rootUri':self.cache.as_uri()})
                (self.target/'.dart_tool/package_config.json').write_text(json.dumps(config))
            return result
        with patch.object(self,'command',side_effect=changed),self.assertRaisesRegex(variant.GateError,'external package root'):
            self.prepare()

    def test_locked_pubget_failure_propagates(self):
        original=self.command
        def failed(argv,cwd,receipt):
            if argv[0]==str(self.sdk/'bin/flutter'):
                raise variant.GateError('offline enforce-lock failed')
            return original(argv,cwd,receipt)
        with patch.object(self,'command',side_effect=failed),self.assertRaisesRegex(variant.GateError,'enforce-lock failed'):
            self.prepare()

    def test_mutated_variant_tracked_source_is_rejected_after_build(self):
        self.prepare();file=self.target/'lib/utils/update.dart';file.write_bytes(file.read_bytes()+b'extra')
        with self.assertRaisesRegex(variant.GateError,'tracked bytes changed'):
            self.finish()

    def test_new_unknown_variant_source_is_rejected(self):
        self.prepare();(self.target/'lib/unknown.dart').write_bytes(b'unknown')
        with self.assertRaisesRegex(variant.GateError,'unknown source/build input'):
            self.finish()

    INJECTIONS = (
        'android/app/src/main/res/values/injected.xml', 'assets/injected.json',
        'assets/fonts/unreviewed.ttf', 'assets/shaders/unreviewed.glsl',
        'android/app/src/main/jniLibs/arm64-v8a/libinjected.so',
        'android/app/CMakeLists.txt', 'android/app/src/main/cpp/injected.c',
        'android/new.gradle', 'android/gradle/new.properties', 'pubspec_extra.yaml',
        'android/app/src/other/AndroidManifest.xml', 'lib/unreviewed.g.dart',
        'assets/.generated/injected.json', 'android/app/build/injected.gradle',
        '.dart_tool/injected.dart',
    )

    def test_all_new_build_input_kinds_rejected_prebuild_and_finalize(self):
        for phase in ('prebuild','finalize'):
            for name in self.INJECTIONS:
                case=VariantTests();case.setUp()
                try:
                    case.prepare();file=case.target/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'actual injected input bytes')
                    with self.subTest(phase=phase,path=name),self.assertRaisesRegex(variant.GateError,'unknown source/build input'):
                        case.prebuild() if phase=='prebuild' else case.finish()
                finally:case.doCleanups()

    def test_original_unknown_build_inputs_rejected_without_copy_or_delete(self):
        for name in self.INJECTIONS:
            case=VariantTests();case.setUp()
            try:
                file=case.source/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'preserved unknown input')
                with self.subTest(path=name),self.assertRaisesRegex(variant.GateError,'unknown source/build input'):
                    case.prepare()
                self.assertEqual(file.read_bytes(),b'preserved unknown input');self.assertFalse(case.target.exists())
            finally:case.doCleanups()

    def test_pubget_cannot_inject_unknown_asset_before_snapshot(self):
        original=self.command
        def injected(argv,cwd,receipt):
            result=original(argv,cwd,receipt)
            if argv[0]==str(self.sdk/'bin/flutter'):
                file=cwd/'assets/injected.json';file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'pubget injected')
            return result
        with patch.object(self,'command',side_effect=injected),self.assertRaisesRegex(variant.GateError,'unknown source/build input'):
            self.prepare()

    def test_known_pubget_and_build_generated_outputs_are_lifecycle_bound(self):
        original=self.command
        def generated(argv,cwd,receipt):
            result=original(argv,cwd,receipt)
            if argv[0]==str(self.sdk/'bin/flutter'):
                for name in variant.PUB_GENERATED | variant.BUILD_GENERATED:
                    if name=='.dart_tool/package_config.json':continue
                    file=cwd/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'known synthetic pubget generated')
            return result
        with patch.object(self,'command',side_effect=generated):self.prepare()
        for name in variant.BUILD_OUTPUTS:
            file=self.target/name/'generated-output.bin';file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'known synthetic build output')
        for name in variant.BUILD_GENERATED:
            (self.target/name).write_bytes(b'known synthetic release generator update')
        with self.assertRaisesRegex(variant.GateError,'build output present before build'):
            self.prebuild()
        self.finish();self.assertEqual(self.receipt['status'],'finalized')
        self.assertEqual(set(self.receipt['finalGeneratedHashes']),variant.BUILD_GENERATED)

    def test_pubget_generated_binding_cannot_change_during_build(self):
        self.prepare();(self.target/'.dart_tool/version').write_bytes(b'unknown pubget change')
        with self.assertRaisesRegex(variant.GateError,'unknown source files changed'):self.finish()

    def test_generated_output_cannot_be_declared_asset_font_shader(self):
        for path in ('build/new.json','.dart_tool/flutter_build/new.glsl','assets/../build/new.ttf','.dart_tool','android/.gradle/new.xml'):
            with self.subTest(path=path),self.assertRaisesRegex(variant.GateError,'declared input overlaps'):
                variant.check_generated_declarations({}, [{'path':path,'declared':path,'directory':path.endswith('/')}])

    def test_android_source_override_cannot_reinterpret_build_outputs(self):
        with self.assertRaisesRegex(variant.GateError,'Android input overlaps'):
            variant.check_generated_declarations({'android/app/build.gradle.kts':b'android { sourceSets { main { res.srcDir("../../build/generated-res") } } }'})

    def test_empty_unknown_input_directory_is_rejected(self):
        self.prepare();(self.target/'assets/unreviewed-empty').mkdir(parents=True)
        with self.assertRaisesRegex(variant.GateError,'unknown source/build input directory'):self.finish()

    def test_tracked_input_cannot_hide_under_generated_roots(self):
        with self.assertRaisesRegex(variant.GateError,'tracked input overlaps'):
            variant.check_generated_declarations({'build/source.dart':b'committed source'})

    def test_symlink_in_source_variant_and_output_is_rejected(self):
        self.prepare()
        for base,name in ((self.source,'lib/injected'),(self.target,'lib/injected'),(self.target,'build/linked')):
            path=base/name;path.parent.mkdir(parents=True,exist_ok=True);path.symlink_to(self.sdk,target_is_directory=True)
            try:
                with self.subTest(path=name),self.assertRaisesRegex(variant.GateError,'symlink'):self.finish()
            finally:path.unlink()

    def test_finalize_requires_explicit_prebuild_check(self):
        self.prepare();self.receipt.pop('prebuildChecked')
        with self.assertRaisesRegex(variant.GateError,'requires prebuild'):self.finish()

    def test_changed_approved_pubget_link_rejected_prebuild_and_finalize(self):
        package=self.cache/'plugin';package.mkdir()
        name='linux/flutter/ephemeral/.plugin_symlinks/plugin'
        self.allowed_links={name:{'packageName':'plugin','canonicalTarget':str(package.resolve())}}
        self.prepare()
        link=self.target/name;link.unlink();link.symlink_to(os.path.relpath(package,link.parent),target_is_directory=True)
        for phase in ('prebuild','finalize'):
            with self.subTest(phase=phase),self.assertRaisesRegex(variant.GateError,'unknown source files changed'):
                self.prebuild() if phase=='prebuild' else self.finish()

    def test_routing_lock_mode_proves_real_HEAD_exact_lock_and_10_paths(self):
        import verify_media_kit_lock as lock
        self.prepare()
        lock.verify_routing_lock(self.target/'pubspec.lock',self.source,self.target,self.media,self.receipt,self.app_sha,self.media_sha)
        file=self.target/'pubspec.lock';file.write_bytes(file.read_bytes()+b'unknown change')
        with self.assertRaisesRegex(ValueError,'exact tracked variant'):
            lock.verify_routing_lock(file,self.source,self.target,self.media,self.receipt,self.app_sha,self.media_sha)

    def test_routing_lock_cannot_be_authorized_by_forged_hash_receipt(self):
        import verify_media_kit_lock as lock
        self.prepare();file=self.target/'pubspec.lock';file.write_bytes(file.read_bytes()+b'unknown change')
        self.receipt['afterHashes']['pubspec.lock']=variant.digest(file.read_bytes())
        with self.assertRaisesRegex(ValueError,'source commit blob'):
            lock.verify_routing_lock(file,self.source,self.target,self.media,self.receipt,self.app_sha,self.media_sha)

    def test_unknown_receipt_hash_is_rejected(self):
        self.prepare();self.receipt['afterHashes']['pubspec.lock']='9'*64
        with self.assertRaisesRegex(variant.GateError,'hash mismatch'):
            self.finish()


class PluginBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.app=self.root/'app';self.app.mkdir()
        self.package=self.root/'cache/plugin-1.0.0';self.package.mkdir(parents=True)
        (self.app/'pubspec.yaml').write_bytes(b'synthetic tracked App manifest')
        (self.package/'pubspec.yaml').write_bytes(b'synthetic package manifest')
        swift=self.package/'darwin/plugin/Package.swift';swift.parent.mkdir(parents=True);swift.write_bytes(b'synthetic Package.swift')
        self.mapping={'piliplus':str(self.app),'plugin':str(self.package)}
        self.manifests=[{'name':'piliplus','inputs':[],'pluginPlatforms':{},'manifestSha256':'app'},
                        {'name':'plugin','inputs':[],'pluginPlatforms':{'linux':{'sharedDarwinSource':False},'ios':{'sharedDarwinSource':True}},'manifestSha256':'plugin'}]
        self.metadata={'plugins':{'linux':[{'name':'plugin','path':str(self.package)}],
                                  'ios':[{'name':'plugin','path':str(self.package),'shared_darwin_source':True}]}}
        self.write_metadata()

    def write_metadata(self):
        (self.app/'.flutter-plugins-dependencies').write_text(json.dumps(self.metadata))

    def context(self):
        with patch.object(variant,'roots',return_value=self.mapping),patch.object(variant,'parse_manifests',return_value=self.manifests):
            return variant.input_context(self.app,self.root/'media',self.root/'sdk',self.root/'cache',self.root/'parser',{'commands':[]})

    def inventory(self,links,phase='prebuild'):
        return variant.source_files(self.app,{'pubspec.yaml':b'synthetic tracked App manifest'},phase,allowed_links=links)

    def install(self,links):
        for name,permit in links.items():
            link=self.app/name;link.parent.mkdir(parents=True,exist_ok=True);link.symlink_to(permit['canonicalTarget'],target_is_directory=True)

    def test_exact_linux_and_shared_darwin_links_authorized_from_package_manifest(self):
        links=self.context()['allowedLinks'];self.install(links)
        inventory=self.inventory(links)
        self.assertEqual(set(inventory['pubLinks']),{'linux/flutter/ephemeral/.plugin_symlinks/plugin','ios/Flutter/ephemeral/Packages/.packages/plugin-1.0.0'})
        self.assertEqual(inventory['pubLinks']['ios/Flutter/ephemeral/Packages/.packages/plugin-1.0.0']['canonicalTarget'],str(self.package/'darwin/plugin'))

    def test_metadata_wrong_package_root_unknown_name_or_shared_flag_rejected(self):
        for mutate in ('root','name','shared'):
            with self.subTest(mutate=mutate):
                original=copy.deepcopy(self.metadata)
                if mutate=='root':self.metadata['plugins']['linux'][0]['path']=str(self.root)
                if mutate=='name':self.metadata['plugins']['linux'][0]['name']='unknown'
                if mutate=='shared':self.metadata['plugins']['ios'][0]['shared_darwin_source']=False
                self.write_metadata()
                with self.assertRaisesRegex(variant.GateError,'metadata'):self.context()
                self.metadata=original

    def test_wrong_cache_package_or_external_link_target_rejected(self):
        links=self.context()['allowedLinks'];self.install(links)
        name='linux/flutter/ephemeral/.plugin_symlinks/plugin';link=self.app/name
        for target in (self.root,self.root/'cache/other-1.0.0'):
            target.mkdir(exist_ok=True);link.unlink();link.symlink_to(target,target_is_directory=True)
            with self.assertRaisesRegex(variant.GateError,'unapproved input symlink'):self.inventory(links)

    def test_parent_directory_symlink_never_authorized(self):
        links=self.context()['allowedLinks'];path=self.app/'linux';path.symlink_to(self.package,target_is_directory=True)
        with self.assertRaisesRegex(variant.GateError,'unapproved input symlink'):self.inventory(links)

    def test_raw_link_changes_detected_even_when_canonical_root_is_same(self):
        links=self.context()['allowedLinks'];self.install(links);before=self.inventory(links)
        link=self.app/'linux/flutter/ephemeral/.plugin_symlinks/plugin';link.unlink();link.symlink_to(os.path.relpath(self.package,link.parent),target_is_directory=True)
        after=self.inventory(links)
        self.assertEqual(before['pubLinks'][link.relative_to(self.app).as_posix()]['canonicalTarget'],after['pubLinks'][link.relative_to(self.app).as_posix()]['canonicalTarget'])
        self.assertNotEqual(before['pubLinks'],after['pubLinks'])

    def test_exact_ephemeral_files_allowed_but_extra_loadable_input_rejected(self):
        links=self.context()['allowedLinks'];self.install(links)
        for name in variant.PUB_GENERATED:
            file=self.app/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(b'synthetic generated regular file')
        self.inventory(links)
        file=self.app/'macos/Flutter/ephemeral/hidden.dart';file.write_bytes(b'loadable unreviewed source')
        with self.assertRaisesRegex(variant.GateError,'unknown source/build input'):self.inventory(links)

    def test_resource_directory_cannot_include_generated_platform_subtree(self):
        with self.assertRaisesRegex(variant.GateError,'declared input overlaps'):
            variant.check_generated_declarations({'macos/known.txt':b'tracked'},[{'declared':'macos/','path':'macos/','directory':True}])


if __name__=='__main__':unittest.main()
