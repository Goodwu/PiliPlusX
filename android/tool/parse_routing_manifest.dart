// Standalone routing input parser. Resolve dependencies with the bootstrap
// Flutter tools package_config; never resolve packages against the App graph.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml/src/scanner.dart';
import 'package:yaml/src/token.dart';

const maxBytes = 4 * 1024 * 1024;

Object? plain(YamlNode node, Set<YamlNode> active, List<int> count, int depth) {
  if (depth > 64 || ++count[0] > 100000 || !active.add(node)) {
    throw const FormatException('YAML depth/node/cyclic alias limit');
  }
  try {
    if (node is YamlMap) {
      final result = <String, Object?>{};
      for (final entry in node.nodes.entries) {
        final key = entry.key.value;
        if (key is! String || result.containsKey(key)) {
          throw const FormatException('YAML mapping keys must be unique strings');
        }
        result[key] = plain(entry.value, active, count, depth + 1);
      }
      return result;
    }
    if (node is YamlList) {
      return [for (final item in node.nodes) plain(item, active, count, depth + 1)];
    }
    if (node is YamlScalar) return node.value;
    throw const FormatException('unsupported YAML node');
  } finally {
    active.remove(node);
  }
}

Map<String, Object?> mapping(Object? value, String label) {
  if (value is! Map<String, Object?>) throw FormatException('$label must be a mapping');
  return value;
}

List<Object?> sequence(Object? value, String label) {
  if (value is! List<Object?>) throw FormatException('$label must be a list');
  return value;
}

String path(Object? value, String label) {
  if (value is! String || value.isEmpty || value.contains('\u0000')) {
    throw FormatException('$label must be a nonempty path string');
  }
  return value;
}

Map<String, Object?> parseManifest(String filename) {
  final file = File(filename);
  if (FileSystemEntity.isLinkSync(filename) || file.lengthSync() > maxBytes) {
    throw const FormatException('manifest must be a bounded regular file');
  }
  final bytes = file.readAsBytesSync();
  final text = utf8.decode(bytes);
  // The locked 3.1.3 scanner exposes lexical tags; public YamlNode drops
  // them. Inspect actual tokens, including directives, before loading nodes.
  final scanner = Scanner(text, sourceUrl: file.absolute.uri);
  var tokenCount = 0;
  while (true) {
    final token = scanner.scan();
    if (++tokenCount > 100000 || token is TagDirectiveToken) {
      throw const FormatException('YAML token/custom tag directive limit');
    }
    if (token is TagToken) {
      final tag = token.handle == '!!' ? 'tag:yaml.org,2002:${token.suffix}' : token.suffix;
      if (!(token.handle == null || token.handle == '!!') ||
          !{'tag:yaml.org,2002:str', 'tag:yaml.org,2002:bool',
            'tag:yaml.org,2002:int', 'tag:yaml.org,2002:float',
            'tag:yaml.org,2002:null', 'tag:yaml.org,2002:seq',
            'tag:yaml.org,2002:map'}.contains(tag)) {
        throw const FormatException('custom YAML tags are unsupported');
      }
    }
    if (token.type == TokenType.streamEnd) break;
  }
  final docs = loadYamlDocuments(text, sourceUrl: file.absolute.uri);
  if (docs.length != 1) throw const FormatException('exactly one YAML document required');
  final data = mapping(plain(docs.single.contents, HashSet.identity(), [0], 0), 'manifest');
  final flutter = data['flutter'] == null ? <String, Object?>{} : mapping(data['flutter'], 'flutter');
  final inputs = <Map<String, Object?>>[];
  void input(Object? value, String kind) {
    final decoded = path(value, kind);
    final uri = Uri.parse(decoded);
    if (uri.hasScheme || uri.hasAuthority || uri.hasQuery || uri.hasFragment || uri.path.startsWith('/') || uri.path.contains('\\') || decoded.contains('\\')) {
      throw const FormatException('resource path must be local and relative');
    }
    inputs.add({'kind': kind, 'declared': decoded, 'path': uri.path, 'directory': uri.path.endsWith('/')});
  }
  void assets(Object? declared) {
    for (final value in sequence(declared, 'assets')) {
      if (value is String) {
        input(value, 'asset');
      } else {
        final entry = mapping(value, 'asset entry');
        if (entry.keys.any((key) => !{'path', 'flavors', 'platforms'}.contains(key))) {
          throw const FormatException('unsupported asset entry fields');
        }
        input(entry['path'], 'asset');
        for (final field in ['flavors', 'platforms']) {
          if (entry.containsKey(field)) {
            for (final selector in sequence(entry[field], 'asset $field')) { path(selector, 'asset $field'); }
          }
        }
      }
    }
  }
  if (flutter.containsKey('assets')) assets(flutter['assets']);
  if (flutter.containsKey('deferred-components')) {
    for (final value in sequence(flutter['deferred-components'], 'deferred components')) {
      final component = mapping(value, 'deferred component');
      if (component.keys.any((key) => !{'name', 'libraries', 'assets'}.contains(key))) {
        throw const FormatException('unsupported deferred component fields');
      }
      path(component['name'], 'deferred component name');
      if (component.containsKey('libraries')) {
        for (final library in sequence(component['libraries'], 'deferred libraries')) {
          path(library, 'deferred library');
        }
      }
      if (component.containsKey('assets')) assets(component['assets']);
    }
  }
  if (flutter.containsKey('shaders')) {
    for (final value in sequence(flutter['shaders'], 'shaders')) { input(value, 'shader'); }
  }
  if (flutter.containsKey('fonts')) {
    for (final value in sequence(flutter['fonts'], 'fonts')) {
      final family = mapping(value, 'font family');
      if (family.keys.any((key) => !{'family', 'fonts'}.contains(key))) {
        throw const FormatException('unsupported font family fields');
      }
      path(family['family'], 'font family');
      for (final item in sequence(family['fonts'], 'font entries')) {
        final font = mapping(item, 'font entry');
        if (font.keys.any((key) => !{'asset', 'weight', 'style'}.contains(key)) ||
            (font.containsKey('weight') && font['weight'] is! int) ||
            (font.containsKey('style') && font['style'] is! String)) {
          throw const FormatException('unsupported font entry/type');
        }
        input(font['asset'], 'font');
      }
    }
  }
  final platforms = <String, Object?>{};
  if (flutter.containsKey('plugin')) {
    final plugin = mapping(flutter['plugin'], 'plugin');
    if (plugin.containsKey('platforms')) {
      for (final entry in mapping(plugin['platforms'], 'plugin platforms').entries) {
        // Flutter supports an empty/null platform map for pure Dart plugins.
        final platform = entry.value == null ? <String, Object?>{} : mapping(entry.value, 'plugin platform');
        final shared = platform['sharedDarwinSource'] ?? false;
        if (shared is! bool || (shared && !{'ios', 'macos'}.contains(entry.key))) {
          throw const FormatException('sharedDarwinSource type/platform mismatch');
        }
        platforms[entry.key] = {'sharedDarwinSource': shared};
      }
    }
  }
  final packages = data['packages'];
  Object? lockYamlVersion;
  if (packages is Map<String, Object?> && packages['yaml'] is Map<String, Object?>) {
    lockYamlVersion = (packages['yaml'] as Map<String, Object?>)['version'];
  }
  return {'schemaVersion': 1, 'manifestSha256': sha256.convert(bytes).toString(),
    'name': data['name'], 'version': data['version'], 'inputs': inputs,
    'pluginPlatforms': platforms, 'lockYamlVersion': lockYamlVersion};
}

void main(List<String> args) {
  try {
    if (args.isEmpty || args.length.isOdd) throw const FormatException('--manifest paths required');
    final results = <Map<String, Object?>>[];
    for (var index = 0; index < args.length; index += 2) {
      if (args[index] != '--manifest') throw const FormatException('unsupported argument');
      results.add(parseManifest(args[index + 1]));
    }
    stdout.writeln(jsonEncode(args.length == 2 ? results.single : {'schemaVersion': 1, 'manifests': results}));
  } catch (error) {
    stderr.writeln('routing manifest rejected: $error');
    exitCode = 1;
  }
}
