import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:piliplus/http/browser_ua.dart';
import 'package:piliplus/http/constants.dart';
import 'package:piliplus/models/video/play/url.dart';

/// Dolby Vision configuration facts read from one DASH rendition's
/// initialization segment (`dvcC`/`dvvC`/`dvwC` box). Bit layout follows
/// FFmpeg `ff_isom_parse_dvcc_dvvc` (libavformat/dovi_isom.c).
class DoviFacts {
  const DoviFacts({
    required this.profile,
    required this.level,
    required this.rpuPresent,
    required this.elPresent,
    required this.blPresent,
    required this.compatibilityId,
    required this.mdCompression,
  });

  final int profile;
  final int level;
  final bool rpuPresent;
  final bool elPresent;
  final bool blPresent;
  final int compatibilityId;
  final int mdCompression;

  @override
  String toString() => 'DoviFacts(profile: $profile, level: $level, '
      'rpu: $rpuPresent, el: $elPresent, bl: $blPresent, '
      'compat: $compatibilityId, md: $mdCompression)';

  static DoviFacts? fromDvccBody(List<int> body) {
    // ff_isom_parse_dvcc_dvvc: needs at least the 4-bit-word body; the
    // compatibility nibble and compression bits arrive in the fifth byte.
    if (body.length < 5) return null;
    final word2 = (body[2] << 8) | body[3];
    final facts = DoviFacts(
      profile: (word2 >> 9) & 0x7f,
      level: (word2 >> 3) & 0x3f,
      rpuPresent: (word2 >> 2) & 0x01 == 1,
      elPresent: (word2 >> 1) & 0x01 == 1,
      blPresent: word2 & 0x01 == 1,
      compatibilityId: (body[4] >> 4) & 0x0f,
      mdCompression: (body[4] >> 2) & 0x03,
    );
    return facts.profile > 0 ? facts : null;
  }
}

/// Sniffs the DOVI configuration record from a DASH rendition without
/// creating a player: one bounded Range GET over the initialization segment,
/// then a bounded ISO-BMFF box walk. Returns null when anything is missing,
/// truncated or unsupported — callers must treat null as "profile unknown",
/// never as a known profile.
Future<DoviFacts?> sniffDoviInitSegment(
  VideoItem item, {
  int maxBytes = 65536,
  Duration timeout = const Duration(seconds: 4),
  Future<List<int>> Function(Uri url, Map<String, String> headers)? fetch,
}) async {
  final base = item.baseUrl;
  if (base == null || base.isEmpty) return null;
  final initEnd = _initializationByteCount(item.segmentBase) ?? maxBytes;
  if (initEnd <= 0 || initEnd > maxBytes) return null;
  try {
    final candidates = <Uri>[
      if (base.isNotEmpty) Uri.parse(base),
      ...?item.backupUrl?.where((u) => u.isNotEmpty).map(Uri.parse),
    ];
    List<int>? body;
    for (final uri in candidates) {
      body = fetch != null
          ? await fetch(uri, _headers).timeout(timeout)
          : await _rangeGet(uri, initEnd, timeout);
      debugPrint(
        'DOVI_SNIFF url=${uri.host} range=0-${initEnd - 1} '
        'bytes=${body.length}',
      );
      if (body.length >= initEnd) break;
    }
    if (body == null || body.length < initEnd) return null;
    if (body.length < initEnd) return null;
    final facts = _parseDoviRecord(body.sublist(0, initEnd));
    debugPrint('DOVI_SNIFF facts=${facts ?? 'none'}');
    return facts;
  } on Object catch (error) {
    debugPrint('DOVI_SNIFF failed: ${error.runtimeType} $error');
    return null;
  }
}

/// Same request identity as the player itself (controller httpHeaders):
/// Bilibili CDN nodes reject other user agents with 403.
const Map<String, String> _headers = {
  'User-Agent': BrowserUa.pc,
  'Referer': HttpString.baseUrl,
};

Future<List<int>> _rangeGet(Uri uri, int byteCount, Duration timeout) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    _headers.forEach(request.headers.set);
    request.headers.set('Range', 'bytes=0-${byteCount - 1}');
    final response = await request.close().timeout(timeout);
    debugPrint('DOVI_SNIFF status=${response.statusCode} from ${uri.host}');
    if (response.statusCode != 206 && response.statusCode != 200) {
      await response.drain<void>();
      return const [];
    }
    return await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    ).timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

int? _initializationByteCount(Map? segmentBase) {
  final init = segmentBase?['initialization'];
  if (init is! String || init.isEmpty) return null;
  final dash = init.split('-');
  if (dash.length != 2) return null;
  final end = int.tryParse(dash[1]);
  if (end == null || end < 0) return null;
  return end + 1;
}

/// Bounded ISO-BMFF walk. Container boxes are descended; `stsd` skips its
/// 8-byte version/flags + entry-count prefix, and each sample entry skips
/// its 78-byte VisualSampleEntry fixed part before descending. `mdat`-style
/// opaque boxes are never scanned. The DOVI configuration box lives inside
/// the sample entry next to `hvcC`.
  DoviFacts? _parseDoviRecord(List<int> data) {
    DoviFacts? found;
    void walk(int start, int end, bool sampleEntries) {
      var off = start;
      while (off + 8 <= end && found == null) {
        final size = (data[off] << 24) | (data[off + 1] << 16) |
            (data[off + 2] << 8) | data[off + 3];
        final type = String.fromCharCodes(data.sublist(off + 4, off + 8));
        var header = 8;
        var declared = size;
        if (size == 1) {
          if (off + 16 > end) return;
          declared = 0;
          for (final b in data.sublist(off + 8, off + 16)) {
            declared = (declared << 8) | b;
          }
          header = 16;
        } else if (size == 0) {
          declared = end - off;
        }
        if (declared < header || off + declared > end) return;
        final boxEnd = off + declared;
        final contentStart = off + header;
      if (type == 'dvcC' || type == 'dvvC' || type == 'dvwC') {
        found = DoviFacts.fromDvccBody(data.sublist(contentStart, boxEnd));
        return;
      }
      const containers = {
        'moov', 'trak', 'edts', 'mdia', 'minf', 'dinf', 'stbl', 'mvex',
      };
      if (containers.contains(type)) {
        walk(contentStart, boxEnd, false);
      } else if (type == 'stsd') {
        walk(contentStart + 8, boxEnd, true);
      } else if (sampleEntries && _sampleEntryTypes.contains(type)) {
        walk(contentStart + 78, boxEnd, false);
      }
      off += declared;
    }
  }

  walk(0, data.length, false);
  return found;
}

const Set<String> _sampleEntryTypes = {
  'hvc1', 'hev1', 'dvh1', 'dvhe', 'avc1', 'avc3', 'av01', 'mp4v',
};
