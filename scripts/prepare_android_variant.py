#!/usr/bin/env python3
"""Prepare/recheck a byte-bound Android/Pink copy; never modify the source App."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path
import shutil
import subprocess

from prepare_routing_ci import package_roots
from verify_hdr_channel import verify as verify_hdr
from verify_routing_native_inputs import GateError, sha
from verify_routing_sources import verify as verify_media

PINK = {
    'lib/utils/update.dart': (b'androidInfo.supportedAbis.first', b'"pink"', 1),
    'android/app/build.gradle.kts': (b'com.example.piliplusx', b'tv.danmaku.bili', 2),
    'android/app/src/profile/AndroidManifest.xml': (b'com.example.piliplusx', b'tv.danmaku.bili', 1),
    'android/app/src/main/AndroidManifest.xml': (b'com.example.piliplusx', b'tv.danmaku.bili', 2),
    'android/app/src/main/kotlin/com/example/piliplusx/MainActivity.kt': (b'com.example.piliplusx', b'tv.danmaku.bili', 1),
    'android/app/src/main/kotlin/com/example/piliplusx/Utils.kt': (b'com.example.piliplusx', b'tv.danmaku.bili', 1),
    'android/app/src/main/kotlin/com/example/piliplusx/BiliDocumentsProvider.kt': (b'com.example.piliplusx', b'tv.danmaku.bili', 1),
    'android/app/src/main/java/com/example/piliplusx/AndroidHelper.java': (b'com.example.piliplusx', b'tv.danmaku.bili', 1),
    'android/app/src/main/java/com/example/piliplusx/MediaHelper.java': (b'com.example.piliplusx', b'tv.danmaku.bili', 1),
    'android/app/src/main/res/xml-v25/shortcuts.xml': (b'com.example.piliplusx', b'tv.danmaku.bili', 2),
    'lib/services/audio_handler.dart': (b'com.example.piliplusx', b'tv.danmaku.bili', 1),
    'lib/utils/android/bindings.g.dart': (b'com/example/piliplusx', b'tv/danmaku/bili', 4),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(argv, cwd, receipt):
    step = {'argv': argv, 'cwd': str(cwd), 'exitCode': None}
    receipt['commands'].append(step)
    result = subprocess.run(argv, cwd=cwd, capture_output=True, check=False)
    step.update(exitCode=result.returncode, stderr=result.stderr.decode('utf-8', errors='replace'))
    if result.returncode:
        raise GateError(f'variant command failed ({result.returncode}): {argv[0]}')
    return result.stdout


def tracked_bytes(source, expected, receipt):
    sha(expected, 'App SHA', 40)
    if command(['git', 'rev-parse', 'HEAD'], source, receipt).decode().strip() != expected:
        raise GateError('variant source App HEAD mismatch')
    command(['git', 'diff', '--exit-code', 'HEAD', '--'], source, receipt)
    listing = command(['git', 'ls-tree', '-rz', '--full-tree', 'HEAD'], source, receipt)
    found = {}
    for item in listing.split(b'\0'):
        if not item:
            continue
        header, path = item.split(b'\t', 1)
        mode, kind, blob = header.decode().split()
        relative = path.decode('utf-8')
        if kind != 'blob' or mode not in ('100644', '100755') or relative.startswith('/') or '..' in Path(relative).parts or '\n' in relative:
            raise GateError('variant requires regular tracked files with safe paths')
        file = source / relative
        if not file.is_file() or file.is_symlink():
            raise GateError('tracked input missing/symlink')
        data = command(['git', 'cat-file', 'blob', blob], source, receipt)
        if data != file.read_bytes():
            raise GateError('tracked input differs from exact commit blob')
        found[relative] = (data, mode)
    if not found:
        raise GateError('empty tracked source tree')
    return found


def expected_variant(files, flavor):
    expected = {name: data for name, (data, _) in files.items()}
    if flavor == 'pink':
        for name, (old, new, count) in PINK.items():
            if name not in expected or expected[name].count(old) != count:
                raise GateError(f'unknown Pink transform occurrence count: {name}')
            expected[name] = expected[name].replace(old, new)
    elif flavor != 'android':
        raise GateError('unknown Android variant')
    return expected


# Only these tool-owned locations may contain untracked generated files. This
# is deliberately independent of .gitignore and applies to every file suffix.
PUB_GENERATED = {
    '.dart_tool/package_config.json', '.dart_tool/package_graph.json',
    '.dart_tool/version', '.packages', '.flutter-plugins',
    'ios/Runner/GeneratedPluginRegistrant.h', 'ios/Runner/GeneratedPluginRegistrant.m',
    'macos/Flutter/GeneratedPluginRegistrant.swift',
    'linux/flutter/generated_plugin_registrant.h', 'linux/flutter/generated_plugin_registrant.cc',
    'linux/flutter/generated_plugins.cmake',
    'windows/flutter/generated_plugin_registrant.h', 'windows/flutter/generated_plugin_registrant.cc',
    'windows/flutter/generated_plugins.cmake',
    '.dart_tool/dartpad/web_plugin_registrant.dart',
    'ios/Flutter/Generated.xcconfig', 'ios/Flutter/flutter_export_environment.sh',
}
for platform in ('ios', 'macos'):
    prefix = platform + '/Flutter/ephemeral/'
    PUB_GENERATED.update(prefix + name for name in (
        'flutter_native_integration.env', '.swift_pm.lock',
        'Packages/.packages/FlutterFramework/Package.swift',
        'Packages/.packages/FlutterFramework/Sources/FlutterFramework/FlutterFramework.swift',
        'Packages/FlutterGeneratedPluginSwiftPackage/Package.swift',
        'Packages/FlutterGeneratedPluginSwiftPackage/Sources/FlutterGeneratedPluginSwiftPackage/FlutterGeneratedPluginSwiftPackage.swift',
    ))
PUB_GENERATED.update('ios/Flutter/ephemeral/' + name for name in ('flutter_lldbinit', 'flutter_lldb_helper.py'))
PUB_GENERATED.update('macos/Flutter/ephemeral/' + name for name in ('Flutter-Generated.xcconfig', 'flutter_export_environment.sh'))
BUILD_GENERATED = {
    '.flutter-plugins-dependencies', 'android/local.properties',
    'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
    'android/gradlew', 'android/gradlew.bat', 'android/gradle/wrapper/gradle-wrapper.jar',
}
BUILD_OUTPUTS = ('build', '.dart_tool/flutter_build', '.dart_tool/dart_build',
                 '.dart_tool/hooks_runner', 'android/.gradle', 'android/.kotlin')


def under_output(name):
    return any(name == root or name.startswith(root + '/') for root in BUILD_OUTPUTS)


def normalized_relative(name):
    parts = []
    for part in name.split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            if not parts:
                raise GateError('declared input escapes App root')
            parts.pop()
        else:
            parts.append(part)
    return '/'.join(parts)


def check_generated_declarations(expected, resources=()):
    for name in expected:
        if under_output(name) or name in PUB_GENERATED or name in BUILD_GENERATED:
            raise GateError('tracked input overlaps reserved generated location: ' + name)
    # Resources here are real YAML + URI decoded by the bound Dart parser.
    # Never reinterpret a raw YAML line with a regex as a resource declaration.
    reserved = set(PUB_GENERATED) | BUILD_GENERATED | set(BUILD_OUTPUTS) | {'.dart_tool', 'ios/Flutter/ephemeral', 'macos/Flutter/ephemeral', 'linux/flutter/ephemeral', 'windows/flutter/ephemeral'}
    for item in resources:
        value = item['path']
        if value.startswith('/') or '\\' in value or ':' in value:
            raise GateError('declared input must be local relative path')
        name = normalized_relative(value)
        if not name or any(name == location or name.startswith(location + '/') or (item['directory'] and location.startswith(name + '/')) for location in reserved):
            raise GateError('declared input overlaps reserved generated location: ' + item['declared'])
        if item['directory']:
            if not any(file.startswith(name + '/') for file in expected):
                raise GateError('declared resource directory has no tracked input: ' + name)
        elif name not in expected:
            raise GateError('declared resource is not a tracked input: ' + name)
    for name, data in expected.items():
        if name.startswith('android/') and (name.endswith(('.gradle', '.gradle.kts', '.cmake')) or Path(name).name in ('CMakeLists.txt', 'Android.mk')):
            text = data.decode('utf-8')
            # The existing output-directory configuration is retained. A new
            # source/native override overlapping a generated location requires
            # an explicit contract review, rather than trusting a new .gradle
            # declaration to convert ignored build outputs into source inputs.
            if re.search(r'sourceSets|srcDir|setSrcDirs|externalNativeBuild|ndkBuild|includeBuild|add_library|target_sources', text) and re.search(r'(?<![A-Za-z0-9_.-])(?:build|\.dart_tool|\.gradle)(?![A-Za-z0-9_.-])', text):
                raise GateError('declared Android input overlaps generated output contract: ' + name)


def source_files(root, expected, phase, *, resources=(), allowed_links=None):
    """Default-deny unknown files; generated exceptions are explicit/lifecycle-bound."""
    check_generated_declarations(expected, resources)
    allowed_links = allowed_links or {}
    inputs, pub, generated, links = {}, {}, {}, {}
    directories = {parent.as_posix() for name in set(expected) | PUB_GENERATED | BUILD_GENERATED | set(allowed_links) for parent in Path(name).parents if parent.as_posix() != '.'}
    def verify_link(path, relative):
        permit = allowed_links.get(relative)
        if permit is None or str(path.resolve(strict=True)) != permit['canonicalTarget']:
            raise GateError('unapproved input symlink: ' + relative)
        links[relative] = dict(permit, rawTarget=os.readlink(path))
    for directory, dirs, files in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in list(dirs):
            path = base / name
            relative = path.relative_to(root).as_posix()
            if relative == '.git' and phase == 'source':
                if path.is_symlink():
                    raise GateError('source Git metadata symlink')
                dirs.remove(name)
                continue
            if path.is_symlink():
                verify_link(path, relative)
                dirs.remove(name)
                continue
            if under_output(relative) and phase == 'prebuild':
                raise GateError('build output present before build: ' + relative)
            if relative not in directories and not (under_output(relative) and phase in ('source', 'finalize')) and not (phase == 'source' and relative in ('scripts/__pycache__', 'test/__pycache__')):
                raise GateError('unknown source/build input directory: ' + relative)
        for name in files:
            path = base / name
            relative = path.relative_to(root).as_posix()
            if phase == 'source' and relative == '.git':
                # Git worktrees use a regular metadata pointer, not product input.
                if path.is_symlink():
                    raise GateError('source Git metadata symlink')
                continue
            if path.is_symlink():
                verify_link(path, relative)
                continue
            if not stat.S_ISREG(path.stat().st_mode):
                raise GateError('input must be a regular file: ' + relative)
            if relative in expected:
                if path.read_bytes() != expected[relative]:
                    raise GateError('variant tracked bytes changed: ' + relative)
                inputs[relative] = digest(expected[relative])
            elif relative in PUB_GENERATED:
                pub[relative] = digest(path.read_bytes())
            elif relative in BUILD_GENERATED:
                generated[relative] = digest(path.read_bytes())
            elif under_output(relative) and phase in ('source', 'finalize'):
                # Outputs are permitted only after the trusted build, never
                # added to the compilation input/hash authorization set.
                continue
            elif phase == 'source' and path.suffix == '.pyc' and path.parent.relative_to(root).as_posix() in ('scripts/__pycache__', 'test/__pycache__'):
                continue
            else:
                raise GateError('unknown source/build input: ' + relative)
    if set(inputs) != set(expected):
        raise GateError('tracked input tree missing files')
    return {'inputs': inputs, 'pubGenerated': pub, 'buildGenerated': generated, 'pubLinks': links}


def roots(root, media, sdk, cache):
    config = root / '.dart_tool/package_config.json'
    verify_media(config, media)
    return package_roots(config, [root, media, sdk, cache])


def parse_manifests(paths, sdk, parser, receipt):
    """Parse using the isolated SDK's locked tools graph, never the App graph."""
    config = sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
    output = command([str(sdk / 'bin/cache/dart-sdk/bin/dart'), '--packages=' + str(config),
                      str(parser), *[arg for path in paths for arg in ('--manifest', str(path))]], parser.parent, receipt)
    data = json.loads(output)
    manifests = [data] if len(paths) == 1 else data.get('manifests')
    if len(paths) != 1 and (set(data) != {'schemaVersion', 'manifests'} or type(data['schemaVersion']) is not int or data['schemaVersion'] != 1):
        raise GateError('manifest parser envelope schema mismatch')
    if not isinstance(manifests, list) or len(manifests) != len(paths):
        raise GateError('manifest parser result count mismatch')
    for file, manifest in zip(paths, manifests):
        keys = {'schemaVersion', 'manifestSha256', 'name', 'version', 'inputs', 'pluginPlatforms', 'lockYamlVersion'}
        if not isinstance(manifest, dict) or set(manifest) != keys or type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1 or manifest['manifestSha256'] != digest(file.read_bytes()):
            raise GateError('manifest parser schema/hash mismatch')
        if any(manifest[field] is not None and not isinstance(manifest[field], str) for field in ('name', 'version', 'lockYamlVersion')):
            raise GateError('manifest parser identity/version type mismatch')
        if not isinstance(manifest['inputs'], list) or not isinstance(manifest['pluginPlatforms'], dict):
            raise GateError('manifest parser input/platform type mismatch')
        for item in manifest['inputs']:
            if not isinstance(item, dict) or set(item) != {'kind', 'declared', 'path', 'directory'} or item['kind'] not in ('asset', 'font', 'shader') or any(not isinstance(item[key], str) or not item[key] for key in ('path', 'declared')) or type(item['directory']) is not bool:
                raise GateError('manifest parser resource schema mismatch')
        for name, platform in manifest['pluginPlatforms'].items():
            if not isinstance(name, str) or not isinstance(platform, dict) or set(platform) != {'sharedDarwinSource'} or type(platform['sharedDarwinSource']) is not bool:
                raise GateError('manifest parser plugin schema mismatch')
    return manifests


def manifest_identity(source, expected, sdk, cache, parser, receipt, bootstrap):
    if parser.is_symlink():
        raise GateError('manifest parser may not be a symlink')
    parser = parser.resolve(strict=True)
    if parser != (source / 'android/tool/parse_routing_manifest.dart').resolve() or parser.is_symlink() or expected.get('android/tool/parse_routing_manifest.dart') != parser.read_bytes():
        raise GateError('manifest parser must be exact tracked candidate App tool')
    config = sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
    if config.is_symlink() or not config.is_file():
        raise GateError('Flutter tools regular package_config required')
    tool_roots = package_roots(config, [sdk, cache])
    if tool_roots != bootstrap.get('flutterToolsPackages'):
        raise GateError('Flutter tools package roots differ from verified bootstrap')
    sdk_head = command(['git', 'rev-parse', 'HEAD'], sdk, receipt).decode().strip()
    if sdk_head != bootstrap.get('sdkCommit'):
        raise GateError('manifest parser SDK HEAD differs from verified bootstrap')
    lock = sdk / 'packages/flutter_tools/pubspec.lock'
    # Flutter's tools lock is generated, not tracked in the SDK checkout.
    # Bind its actual bytes and verified roots now and keep them immutable.
    if lock.is_symlink() or not lock.is_file():
        raise GateError('Flutter tools regular lock required')
    locked_bytes = lock.read_bytes()
    yaml_root = Path(tool_roots.get('yaml', ''))
    parsed_lock, parsed_yaml = parse_manifests([lock, yaml_root / 'pubspec.yaml'], sdk, parser, receipt)
    if parsed_lock['lockYamlVersion'] != '3.1.3' or parsed_yaml['name'] != 'yaml' or parsed_yaml['version'] != '3.1.3':
        raise GateError('manifest parser requires locked yaml 3.1.3 closure')
    return {'parserPath': str(parser), 'parserSha256': digest(parser.read_bytes()),
            'helperSha256': digest(Path(__file__).read_bytes()), 'sdkCommit': sdk_head,
            'toolsConfigSha256': digest(config.read_bytes()), 'toolsPackageRoots': tool_roots,
            'toolsLockSha256': digest(locked_bytes), 'yamlRoot': str(yaml_root),
            'yamlManifestSha256': parsed_yaml['manifestSha256'], 'yamlVersion': '3.1.3',
            'yamlImplementationHashes': {name: digest((yaml_root / name).read_bytes()) for name in (
                'lib/yaml.dart', 'lib/src/scanner.dart', 'lib/src/token.dart',
                'lib/src/parser.dart', 'lib/src/loader.dart')}}


def input_context(root, media, sdk, cache, parser, receipt):
    mapping = roots(root, media, sdk, cache)
    names = sorted(mapping)
    manifests = parse_manifests([Path(mapping[name]) / 'pubspec.yaml' for name in names], sdk, parser, receipt)
    packages = dict(zip(names, manifests))
    for name, manifest in packages.items():
        if manifest['name'] != name:
            raise GateError('package manifest name differs from verified package root: ' + name)
    app = packages.get('piliplus')
    if app is None or Path(mapping['piliplus']) != root.resolve():
        raise GateError('App manifest root mismatch')
    links = {}
    metadata = root / '.flutter-plugins-dependencies'
    if metadata.exists():
        if metadata.is_symlink():
            raise GateError('plugin metadata may not be a symlink')
        document = json.loads(metadata.read_bytes())
        if not isinstance(document, dict) or not isinstance(document.get('plugins'), dict):
            raise GateError('plugin metadata platform mapping required')
        for platform, entries in document['plugins'].items():
            if platform not in ('ios', 'android', 'macos', 'linux', 'windows', 'web') or not isinstance(entries, list):
                raise GateError('plugin metadata unsupported platform/type')
            seen = set()
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get('name'), str) or not isinstance(entry.get('path'), str):
                    raise GateError('plugin metadata entry type mismatch')
                name = entry['name']
                if name in seen or name not in packages or platform not in packages[name]['pluginPlatforms'] or Path(entry['path']).resolve(strict=True) != Path(mapping[name]):
                    raise GateError('plugin metadata differs from package_config/pubspec: ' + name)
                seen.add(name)
                shared = packages[name]['pluginPlatforms'][platform]['sharedDarwinSource']
                if entry.get('shared_darwin_source', False) is not shared:
                    raise GateError('plugin metadata shared Darwin source differs from pubspec')
                package = Path(mapping[name])
                if platform in ('linux', 'windows'):
                    link = f'{platform}/flutter/ephemeral/.plugin_symlinks/{name}'
                    target = package
                elif platform in ('ios', 'macos'):
                    target = package / ('darwin' if shared else platform) / name
                    if not (target / 'Package.swift').is_file():
                        continue  # CocoaPods plugin has no SPM link authorization.
                    target = target.resolve(strict=True)
                    if not target.is_relative_to(package) or (target / 'Package.swift').is_symlink():
                        raise GateError('Swift package input escapes exact package root')
                    link = f'{platform}/Flutter/ephemeral/Packages/.packages/{package.name}'
                else:
                    continue
                if link in links:
                    raise GateError('ambiguous generated plugin link')
                links[link] = {'packageName': name, 'canonicalTarget': str(target)}
    return {'packageRoots': mapping, 'resources': app['inputs'], 'allowedLinks': links,
            'packageManifestHashes': {name: manifest['manifestSha256'] for name, manifest in packages.items()}}


def prepare(source, media, variant, expected_app, expected_media, flavor, receipt, bootstrap, *, manifest_parser=None):
    receipt.update(scope='routing-android-variant', status='failed', stage='source', flavor=flavor,
                   appCommit=expected_app, mediaKitCommit=expected_media, commands=[])
    if bootstrap.get('status') != 'prepared-source-only' or bootstrap.get('vector', {}).get('app') != expected_app or bootstrap.get('vector', {}).get('media-kit') != expected_media:
        raise GateError('variant requires prepared exact bootstrap vector')
    sdk, cache = Path(bootstrap['flutterRoot']), Path(bootstrap['pubCache'])
    if Path(os.environ.get('FLUTTER_ROOT', '')).resolve() != sdk.resolve() or Path(os.environ.get('PUB_CACHE', '')).resolve() != cache.resolve():
        raise GateError('variant must use the bootstrap private SDK/cache')
    files = tracked_bytes(source, expected_app, receipt)
    expected = expected_variant(files, flavor)
    parser = manifest_parser or source / 'android/tool/parse_routing_manifest.dart'
    receipt['manifestParser'] = manifest_identity(source, expected, sdk, cache, parser, receipt, bootstrap)
    before_context = input_context(source, media, sdk, cache, parser, receipt)
    source_files(source, {name: data for name, (data, _) in files.items()}, 'source', resources=before_context['resources'], allowed_links=before_context['allowedLinks'])
    temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    parent = variant.absolute().parent
    if parent.exists() or not parent.resolve().is_relative_to(temporary) or parent.resolve() == temporary:
        raise GateError('variant requires a fresh private workspace')
    for ancestor in parent.parents:
        if ancestor.resolve() == temporary:
            break
        if ancestor.is_symlink():
            raise GateError('variant parent may not traverse symlink')
    parent.mkdir(parents=True, mode=0o700)
    variant.mkdir()
    # Preserve the exact tracked relative overrides/lock bytes while resolving
    # ../media-kit to the existing trusted checkout. Never copy/mutate native roots.
    (parent / 'media-kit').symlink_to(media.resolve(strict=True), target_is_directory=True)
    receipt['stage'] = 'copy-transform'
    for name, data in expected.items():
        destination = variant / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod(0o755 if files[name][1] == '100755' else 0o644)
    failures = verify_hdr(variant)
    if failures:
        raise GateError('variant HDR channel contract: ' + '; '.join(failures))
    receipt['beforeHashes'] = {name: digest(data) for name, (data, _) in files.items()}
    receipt['afterHashes'] = {name: digest(data) for name, data in expected.items()}
    receipt['sourceRoot'] = str(source.resolve())
    receipt['variantRoot'] = str(variant.resolve())
    receipt['mediaKitRoot'] = str(media.resolve())
    receipt['flutterRoot'], receipt['pubCache'] = str(sdk), str(cache)
    before_roots = before_context['packageRoots']
    receipt['stage'] = 'offline-locked-resolution'
    flutter = sdk / 'bin/flutter'
    command([str(flutter), 'pub', 'get', '--offline', '--enforce-lockfile'], variant, receipt)
    after_roots = roots(variant, media, sdk, cache)
    expected_roots = dict(before_roots)
    app_names = [name for name, path in before_roots.items() if Path(path) == source.resolve()]
    if app_names != ['piliplus']:
        raise GateError('exactly the App package root must move')
    expected_roots['piliplus'] = str(variant.resolve())
    if after_roots != expected_roots:
        raise GateError('variant resolution changed an external package root')
    for name, data in expected.items():
        if (variant / name).read_bytes() != data:
            raise GateError('locked resolution modified tracked variant bytes: ' + name)
    receipt['packageRoots'] = after_roots
    context = input_context(variant, media, sdk, cache, parser, receipt)
    if context['packageManifestHashes'] != before_context['packageManifestHashes']:
        raise GateError('variant package manifests changed after offline resolution')
    receipt['inputContext'] = context
    receipt['bootstrapTools'] = {key: bootstrap[key] for key in ('sdkCommit', 'flutterToolsPackages')}
    receipt['sourceFiles'] = source_files(variant, expected, 'prebuild', resources=context['resources'], allowed_links=context['allowedLinks'])
    receipt.update(status='prepared', stage='complete')


def finalize(source, media, variant, expected_app, expected_media, flavor, receipt, *, prebuild=False, manifest_parser=None):
    if receipt.get('status') != 'prepared' or receipt.get('flavor') != flavor or receipt.get('appCommit') != expected_app or receipt.get('mediaKitCommit') != expected_media or receipt.get('variantRoot') != str(variant.resolve()) or receipt.get('sourceRoot') != str(source.resolve()) or receipt.get('mediaKitRoot') != str(media.resolve()):
        raise GateError('variant finalization identity mismatch/unprepared')
    if not prebuild and receipt.get('prebuildChecked') is not True:
        raise GateError('variant requires prebuild source verification before finalization')
    files = tracked_bytes(source, expected_app, receipt)
    expected = expected_variant(files, flavor)
    if receipt['beforeHashes'] != {name: digest(data) for name, (data, _) in files.items()} or receipt['afterHashes'] != {name: digest(data) for name, data in expected.items()}:
        raise GateError('variant receipt source/transform hash mismatch')
    for name, data in expected.items():
        file = variant / name
        if not file.is_file() or file.is_symlink() or file.read_bytes() != data:
            raise GateError('variant tracked bytes changed: ' + name)
    sdk, cache = Path(receipt['flutterRoot']), Path(receipt['pubCache'])
    parser = manifest_parser or source / 'android/tool/parse_routing_manifest.dart'
    identity = manifest_identity(source, expected, sdk, cache, parser, receipt, receipt['bootstrapTools'])
    if identity != receipt['manifestParser']:
        raise GateError('manifest parser SDK/tool/config identity changed')
    before_context = input_context(source, media, sdk, cache, parser, receipt)
    source_files(source, {name: data for name, (data, _) in files.items()}, 'source', resources=before_context['resources'], allowed_links=before_context['allowedLinks'])
    context = input_context(variant, media, sdk, cache, parser, receipt)
    if context != receipt['inputContext']:
        raise GateError('variant manifest/plugin/source closure changed')
    inventory = source_files(variant, expected, 'prebuild' if prebuild else 'finalize', resources=context['resources'], allowed_links=context['allowedLinks'])
    baseline = receipt['sourceFiles']
    if inventory['inputs'] != baseline['inputs'] or inventory['pubGenerated'] != baseline['pubGenerated'] or inventory['pubLinks'] != baseline['pubLinks'] or (prebuild and inventory['buildGenerated'] != baseline['buildGenerated']):
        raise GateError('variant generated/unknown source files changed')
    if not prebuild:
        receipt['finalGeneratedHashes'] = inventory['buildGenerated']
    if roots(variant, media, Path(receipt['flutterRoot']), Path(receipt['pubCache'])) != receipt['packageRoots']:
        raise GateError('variant external package roots changed')
    failures = verify_hdr(variant)
    if failures:
        raise GateError('variant final HDR channel contract failed')
    if prebuild:
        receipt['prebuildChecked'] = True
    else:
        receipt.update(status='finalized', stage='complete')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'media-kit-root', 'variant', 'receipt', 'bootstrap'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--app-commit', required=True)
    parser.add_argument('--media-kit-commit', required=True)
    parser.add_argument('--flavor', choices=('android', 'pink'), required=True)
    parser.add_argument('--manifest-parser', type=Path, required=True)
    lifecycle = parser.add_mutually_exclusive_group()
    lifecycle.add_argument('--finalize', action='store_true')
    lifecycle.add_argument('--check-prebuild', action='store_true')
    args = parser.parse_args()
    receipt = {'scope': 'routing-android-variant', 'status': 'failed', 'commands': []}
    code = 0
    try:
        if args.finalize or args.check_prebuild:
            receipt = json.loads(args.receipt.read_text())
            finalize(args.source, args.media_kit_root, args.variant, args.app_commit, args.media_kit_commit, args.flavor, receipt, prebuild=args.check_prebuild, manifest_parser=args.manifest_parser)
        else:
            prepare(args.source, args.media_kit_root, args.variant, args.app_commit, args.media_kit_commit, args.flavor, receipt, json.loads(args.bootstrap.read_text()), manifest_parser=args.manifest_parser)
    except Exception as error:
        receipt.update(status='failed', reason=str(error))
        code = 1
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    if code == 0 and not args.finalize and not args.check_prebuild and os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as stream:
            stream.write(f'variant={args.variant.resolve()}\n')
    print(f"routing Android variant: {receipt['status']}")
    return code


if __name__ == '__main__':
    raise SystemExit(main())
