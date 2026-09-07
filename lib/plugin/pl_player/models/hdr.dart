import 'package:PiliPlus/models/common/enum_with_label.dart';

/// HDR policy and capability primitives shared by every platform backend.
///
/// This layer deliberately does not infer HDR support from a successful
/// Flutter build. Native backends must populate [HdrCapabilities] with facts
/// reported by the OS, display and decoder before selecting native HDR.
enum HdrMode implements EnumWithLabel {
  auto('自动 HDR'),
  off('关闭'),
  ;

  @override
  final String label;
  const HdrMode(this.label);
}

enum HdrOutputMode { nativeHdr, toneMappedSdr, sdr }

enum HdrTransfer { unknown, sdr, pq, hlg }

enum HdrPrimaries { unknown, bt709, bt2020 }

enum HdrMatrix { unknown, bt709, bt2020, rgb }

enum HdrSourceKind {
  sdr,
  hdr10,
  hlg,
  hdr10Plus,
  dolbyVision,
  hdrVivid,
  unknown,
}

/// Dolby Vision enhancement-layer classification.  `fel` is intentionally
/// not treated as a complete DV path by the stable (mpv 0.41) playback stack.
enum DvEnhancementType { none, mel, fel, unknown }

class HdrSourceMetadata {
  final HdrSourceKind kind;
  final HdrTransfer transfer;
  final HdrPrimaries primaries;
  final HdrMatrix matrix;
  final String? dolbyVisionProfile;
  final String? dolbyVisionLevel;
  final bool rpuPresent;
  final bool baseLayerPresent;
  final bool enhancementLayerPresent;
  final DvEnhancementType dvEnhancement;
  final int bitDepth;
  final Map<String, Object?> masteringMetadata;
  final bool dynamicMetadataPresent;

  /// Fields actually observed from a decoder callback.  Empty/default values
  /// in an mpv callback must not erase a stronger source hint.
  final Set<String> observedFields;

  const HdrSourceMetadata({
    this.kind = HdrSourceKind.unknown,
    this.transfer = HdrTransfer.unknown,
    this.primaries = HdrPrimaries.unknown,
    this.matrix = HdrMatrix.unknown,
    this.dolbyVisionProfile,
    this.dolbyVisionLevel,
    this.rpuPresent = false,
    this.baseLayerPresent = true,
    this.enhancementLayerPresent = false,
    this.dvEnhancement = DvEnhancementType.none,
    this.bitDepth = 8,
    this.masteringMetadata = const <String, Object?>{},
    this.dynamicMetadataPresent = false,
    this.observedFields = const <String>{},
  });

  bool observed(String field) => observedFields.contains(field);

  bool get isHdr =>
      kind != HdrSourceKind.sdr &&
      (kind != HdrSourceKind.unknown ||
          transfer == HdrTransfer.pq ||
          transfer == HdrTransfer.hlg ||
          primaries == HdrPrimaries.bt2020 ||
          matrix == HdrMatrix.bt2020);

  bool get hasNativeColorMetadata =>
      (transfer == HdrTransfer.pq || transfer == HdrTransfer.hlg) &&
      (primaries == HdrPrimaries.bt2020 || matrix == HdrMatrix.bt2020);

  bool get isDolbyVisionP7 =>
      kind == HdrSourceKind.dolbyVision &&
      (dolbyVisionProfile?.split('.').first == '7' ||
          dolbyVisionProfile?.startsWith('07') == true);

  /// Stable mpv 0.41 policy: P7 is playable only through its HDR10 base layer.
  bool get requiresHdr10BaseLayerFallback =>
      isDolbyVisionP7 &&
      baseLayerPresent &&
      (dvEnhancement == DvEnhancementType.none ||
          dvEnhancement == DvEnhancementType.mel ||
          dvEnhancement == DvEnhancementType.fel ||
          dvEnhancement == DvEnhancementType.unknown);

  /// Whether decoded DV can be converted to ordinary HDR output.
  ///
  /// This is not Dolby Vision metadata passthrough. A non-P7 stream with a
  /// usable base layer and PQ/HLG + BT.2020 metadata can use the ordinary HDR
  /// output once the platform surface is proven.
  bool get supportsConvertedHdrOutput =>
      kind == HdrSourceKind.dolbyVision &&
      !isDolbyVisionP7 &&
      baseLayerPresent &&
      hasNativeColorMetadata;

  /// Bilibili exposes HDR as a quality tier before the file is opened. This
  /// is only an initial hint; [fromMpvProperties] remains authoritative once
  /// mpv reports the decoded video parameters.
  factory HdrSourceMetadata.fromBilibiliHints({
    int? quality,
    String? codec,
  }) {
    final normalizedCodec = codec?.toLowerCase();
    final kind = switch (quality) {
      126 => HdrSourceKind.dolbyVision,
      129 => HdrSourceKind.hdrVivid,
      125 => HdrSourceKind.hdr10,
      _
          when normalizedCodec?.contains('dolby') == true ||
              normalizedCodec?.contains('dv') == true =>
        HdrSourceKind.dolbyVision,
      _ when normalizedCodec?.contains('vivid') == true =>
        HdrSourceKind.hdrVivid,
      _ => quality == null ? HdrSourceKind.unknown : HdrSourceKind.sdr,
    };
    return HdrSourceMetadata(
      kind: kind,
      transfer: kind == HdrSourceKind.hlg
          ? HdrTransfer.hlg
          : kind == HdrSourceKind.sdr
          ? HdrTransfer.sdr
          : kind == HdrSourceKind.unknown
          ? HdrTransfer.unknown
          : HdrTransfer.pq,
      primaries: kind == HdrSourceKind.sdr || kind == HdrSourceKind.unknown
          ? HdrPrimaries.unknown
          : HdrPrimaries.bt2020,
    );
  }

  /// Corrects the initial quality/codec guess with mpv's video-params.
  /// Values are intentionally strings because media-kit exposes mpv
  /// properties as strings on different native versions.
  factory HdrSourceMetadata.fromMpvProperties(Map<String, String> values) {
    final transfer = switch (values['transfer']?.toLowerCase()) {
      'pq' || 'smpte2084' || 'st2084' => HdrTransfer.pq,
      'hlg' || 'arib-std-b67' => HdrTransfer.hlg,
      'bt.1886' || 'srgb' || 'gamma2.2' => HdrTransfer.sdr,
      _ => HdrTransfer.unknown,
    };
    final primaries = switch (values['primaries']?.toLowerCase()) {
      'bt.2020' || 'bt2020' => HdrPrimaries.bt2020,
      'bt.709' || 'bt709' => HdrPrimaries.bt709,
      _ => HdrPrimaries.unknown,
    };
    final matrix = switch (values['matrix']?.toLowerCase()) {
      'bt.2020' ||
      'bt.2020-ncl' ||
      'bt2020' ||
      'bt2020-ncl' => HdrMatrix.bt2020,
      'bt.709' || 'bt709' => HdrMatrix.bt709,
      'rgb' => HdrMatrix.rgb,
      _ => HdrMatrix.unknown,
    };
    final codecValue = values['codec']?.toLowerCase();
    final kind = switch (codecValue) {
      final codec? when codec.contains('dolby') || codec.contains('dv') =>
        HdrSourceKind.dolbyVision,
      final codec? when codec.contains('vivid') => HdrSourceKind.hdrVivid,
      final codec?
          when codec.contains('hdr10+') || codec.contains('hdr10plus') =>
        HdrSourceKind.hdr10Plus,
      _
          when values['dolby-vision-profile'] != null ||
              values['dv-profile'] != null =>
        HdrSourceKind.dolbyVision,
      _
          when values['hdr10+'] != null ||
              values['hdr10plus'] != null ||
              values['hdr10plus-present'] != null =>
        HdrSourceKind.hdr10Plus,
      _ when transfer == HdrTransfer.hlg => HdrSourceKind.hlg,
      _ when transfer == HdrTransfer.pq && primaries == HdrPrimaries.bt2020 =>
        HdrSourceKind.hdr10,
      _ when transfer == HdrTransfer.sdr || primaries == HdrPrimaries.bt709 =>
        HdrSourceKind.sdr,
      _ => HdrSourceKind.unknown,
    };
    final observedFields = <String>{};
    if (transfer != HdrTransfer.unknown) observedFields.add('transfer');
    if (primaries != HdrPrimaries.unknown) observedFields.add('primaries');
    if (matrix != HdrMatrix.unknown) observedFields.add('matrix');
    if (kind != HdrSourceKind.unknown) observedFields.add('kind');
    if (values['dolby-vision-profile'] != null ||
        values['dv-profile'] != null) {
      observedFields.add('dolbyVisionProfile');
    }
    if (values['dolby-vision-level'] != null || values['dv-level'] != null) {
      observedFields.add('dolbyVisionLevel');
    }
    if (_hasRecognizedBool(values, const [
      'rpu',
      'rpu-present',
      'dolby-vision-rpu',
    ])) {
      observedFields.add('rpuPresent');
    }
    if (_hasRecognizedBool(values, const [
      'bl',
      'base-layer',
      'base-layer-present',
    ])) {
      observedFields.add('baseLayerPresent');
    }
    if (_hasRecognizedBool(values, const [
      'el',
      'enhancement-layer',
      'enhancement-layer-present',
    ])) {
      observedFields.add('enhancementLayerPresent');
    }
    if (values.containsKey('dolby-vision-enhancement') ||
        values.containsKey('dv-enhancement') ||
        _hasRecognizedBool(values, const ['el', 'enhancement-layer'])) {
      observedFields.add('dvEnhancement');
    }
    final parsedBitDepth = int.tryParse(
      values['bit-depth'] ?? values['bitdepth'] ?? '',
    );
    if (parsedBitDepth != null) observedFields.add('bitDepth');
    if (_hasRecognizedBool(values, const [
      'hdr10+',
      'hdr10plus',
      'dynamic-metadata',
      'hdr10plus-present',
      'side-data-dynamic-hdr10+',
    ])) {
      observedFields.add('dynamicMetadataPresent');
    }
    return HdrSourceMetadata(
      kind: kind,
      transfer: transfer,
      primaries: primaries,
      matrix: matrix,
      dolbyVisionProfile:
          values['dolby-vision-profile'] ?? values['dv-profile'],
      dolbyVisionLevel: values['dolby-vision-level'] ?? values['dv-level'],
      rpuPresent: _boolProperty(values, const [
        'rpu',
        'rpu-present',
        'dolby-vision-rpu',
      ]),
      baseLayerPresent: !_explicitFalse(values, const [
        'bl',
        'base-layer',
        'base-layer-present',
      ]),
      enhancementLayerPresent: _boolProperty(values, const [
        'el',
        'enhancement-layer',
        'enhancement-layer-present',
      ]),
      dvEnhancement: _dvEnhancement(values),
      bitDepth: parsedBitDepth ?? 8,
      dynamicMetadataPresent: _boolProperty(values, const [
        'hdr10+',
        'hdr10plus',
        'dynamic-metadata',
        'hdr10plus-present',
        'side-data-dynamic-hdr10+',
      ]),
      masteringMetadata: <String, Object?>{
        for (final key in const [
          'mastering-display',
          'mastering-display-metadata',
          'mastering-display-primaries',
          'mastering-display-luminance',
          'max-cll',
          'max-fall',
        ])
          if (values[key] != null) key: values[key],
      },
      observedFields: observedFields,
    );
  }

  /// Merge decoder metadata into the initial stream hint.
  ///
  /// mpv commonly reports a Dolby Vision base layer as ordinary HEVC PQ/
  /// BT.2020. Keep the already verified Dolby Vision identity in that case;
  /// PQ/BT.2020 alone is not evidence that a DV stream became HDR10.
  HdrSourceMetadata mergeMpvCorrection(HdrSourceMetadata correction) {
    final correctionLooksLikeHdrBaseLayer =
        (correction.transfer == HdrTransfer.pq ||
            correction.transfer == HdrTransfer.hlg) &&
        (correction.primaries == HdrPrimaries.bt2020 ||
            correction.matrix == HdrMatrix.bt2020);
    final preserveDolbyIdentity =
        kind == HdrSourceKind.dolbyVision &&
        correction.kind != HdrSourceKind.dolbyVision &&
        correctionLooksLikeHdrBaseLayer;
    final preserveHdrVividIdentity =
        kind == HdrSourceKind.hdrVivid &&
        correction.kind != HdrSourceKind.hdrVivid &&
        correctionLooksLikeHdrBaseLayer;
    final mergedKind = preserveDolbyIdentity
        ? HdrSourceKind.dolbyVision
        : preserveHdrVividIdentity
        ? HdrSourceKind.hdrVivid
        : !correction.observed('kind')
        ? kind
        : correction.kind;
    return HdrSourceMetadata(
      kind: mergedKind,
      transfer: correction.observed('transfer')
          ? correction.transfer
          : transfer,
      primaries: correction.observed('primaries')
          ? correction.primaries
          : primaries,
      matrix: correction.observed('matrix') ? correction.matrix : matrix,
      dolbyVisionProfile: correction.observed('dolbyVisionProfile')
          ? correction.dolbyVisionProfile
          : dolbyVisionProfile,
      dolbyVisionLevel: correction.observed('dolbyVisionLevel')
          ? correction.dolbyVisionLevel
          : dolbyVisionLevel,
      rpuPresent: correction.observed('rpuPresent')
          ? correction.rpuPresent
          : rpuPresent,
      baseLayerPresent: correction.observed('baseLayerPresent')
          ? correction.baseLayerPresent
          : baseLayerPresent,
      enhancementLayerPresent: correction.observed('enhancementLayerPresent')
          ? correction.enhancementLayerPresent
          : enhancementLayerPresent,
      dvEnhancement: correction.observed('dvEnhancement')
          ? correction.dvEnhancement
          : dvEnhancement,
      bitDepth: correction.observed('bitDepth')
          ? correction.bitDepth
          : bitDepth,
      masteringMetadata: {
        ...masteringMetadata,
        ...correction.masteringMetadata,
      },
      dynamicMetadataPresent: correction.observed('dynamicMetadataPresent')
          ? correction.dynamicMetadataPresent
          : dynamicMetadataPresent,
      observedFields: {...observedFields, ...correction.observedFields},
    );
  }

  static bool _hasRecognizedBool(
    Map<String, String> values,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = values[key]?.toLowerCase();
      if (value == 'yes' ||
          value == 'true' ||
          value == '1' ||
          value == 'present' ||
          value == 'enabled' ||
          value == 'no' ||
          value == 'false' ||
          value == '0' ||
          value == 'absent' ||
          value == 'disabled') {
        return true;
      }
    }
    return false;
  }

  static bool _boolProperty(Map<String, String> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key]?.toLowerCase();
      if (value == 'yes' ||
          value == 'true' ||
          value == '1' ||
          value == 'present' ||
          value == 'enabled') {
        return true;
      }
    }
    return false;
  }

  static bool _explicitFalse(Map<String, String> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key]?.toLowerCase();
      if (value == 'no' ||
          value == 'false' ||
          value == '0' ||
          value == 'absent' ||
          value == 'disabled') {
        return true;
      }
    }
    return false;
  }

  static DvEnhancementType _dvEnhancement(Map<String, String> values) {
    final value =
        (values['dolby-vision-enhancement'] ?? values['dv-enhancement'] ?? '')
            .toLowerCase();
    if (value.contains('fel')) return DvEnhancementType.fel;
    if (value.contains('mel')) return DvEnhancementType.mel;
    if (value == 'none' || value == 'no') return DvEnhancementType.none;
    if (_boolProperty(values, const ['el', 'enhancement-layer'])) {
      return DvEnhancementType.unknown;
    }
    return DvEnhancementType.none;
  }
}

class HdrCapabilities {
  final String platform;
  final String nativeBackend;
  final int? androidApi;
  final bool displayHdr;

  /// Current compositor headroom for the display containing the output.
  /// This is diagnostic state; native activation still requires active proof.
  final double? headroom;

  /// Potential display headroom, which permits an EDR attempt but does not
  /// prove that native output is active or visibly above the SDR white point.
  final double? potentialHeadroom;
  final bool decoderHdr;
  final bool nativeOutput;

  /// Whether the platform backend can be attempted (surface/window path exists).
  /// This is intentionally separate from [nativeOutputActive].
  final bool nativeOutputCapable;

  /// Whether a configured native output is currently active and verified.
  final bool nativeOutputActive;
  final bool vulkan;
  final bool platformView;
  final bool hcpp;
  final bool toneMapping;
  final Set<String> displayFormats;
  final Set<String> decoderProfiles;
  final Set<String> supportedInputFormats;
  final Set<String> supportedOutputFormats;
  final String? unsupportedReason;

  const HdrCapabilities({
    this.platform = 'unknown',
    this.nativeBackend = 'none',
    this.androidApi,
    this.displayHdr = false,
    this.headroom,
    this.potentialHeadroom,
    this.decoderHdr = false,
    this.nativeOutput = false,
    bool? nativeOutputCapable,
    bool? nativeOutputActive,
    this.vulkan = false,
    this.platformView = false,
    this.hcpp = false,
    this.toneMapping = true,
    this.displayFormats = const <String>{},
    this.decoderProfiles = const <String>{},
    this.supportedInputFormats = const <String>{},
    this.supportedOutputFormats = const <String>{},
    this.unsupportedReason,
  }) : nativeOutputCapable = nativeOutputCapable ?? nativeOutput,
       nativeOutputActive = nativeOutputActive ?? nativeOutput;

  /// Whether a fresh display probe changes display facts. Native output state
  /// is deliberately excluded: a no-op probe must not clear an active output.
  bool displayStateChangedFrom(HdrCapabilities previous) =>
      displayHdr != previous.displayHdr ||
      headroom != previous.headroom ||
      potentialHeadroom != previous.potentialHeadroom;

  bool get canNativeHdr => displayHdr && decoderHdr && nativeOutputActive;

  /// HCPP is a provisional native-output path: the surface must exist before
  /// its dataspace can be applied and verified against the actual stream.
  bool get canNativeHdrCandidate => canNativeHdr || canHcpp;

  bool get canHcpp =>
      hcpp &&
      displayHdr &&
      decoderHdr &&
      platformView &&
      vulkan &&
      (androidApi ?? 0) >= 34;

  HdrCapabilities copyWith({
    String? platform,
    String? nativeBackend,
    bool? displayHdr,
    double? headroom,
    double? potentialHeadroom,
    bool? hcpp,
    bool? nativeOutput,
    bool? nativeOutputCapable,
    bool? nativeOutputActive,
    bool? decoderHdr,
    String? unsupportedReason,
  }) => HdrCapabilities(
    platform: platform ?? this.platform,
    nativeBackend: nativeBackend ?? this.nativeBackend,
    androidApi: androidApi,
    displayHdr: displayHdr ?? this.displayHdr,
    headroom: headroom ?? this.headroom,
    potentialHeadroom: potentialHeadroom ?? this.potentialHeadroom,
    decoderHdr: decoderHdr ?? this.decoderHdr,
    nativeOutput: nativeOutput ?? nativeOutputActive ?? this.nativeOutput,
    nativeOutputCapable: nativeOutputCapable ?? this.nativeOutputCapable,
    nativeOutputActive: nativeOutputActive ?? this.nativeOutputActive,
    vulkan: vulkan,
    platformView: platformView,
    hcpp: hcpp ?? this.hcpp,
    toneMapping: toneMapping,
    displayFormats: displayFormats,
    decoderProfiles: decoderProfiles,
    supportedInputFormats: supportedInputFormats,
    supportedOutputFormats: supportedOutputFormats,
    unsupportedReason: unsupportedReason ?? this.unsupportedReason,
  );

  factory HdrCapabilities.fromMap(Map<Object?, Object?> values) {
    bool flag(String key) => values[key] == true;
    final api = values['androidApi'];
    return HdrCapabilities(
      platform: values['platform'] as String? ?? 'unknown',
      nativeBackend: values['nativeBackend'] as String? ?? 'none',
      androidApi: api is int ? api : null,
      displayHdr: flag('displayHdr'),
      headroom: values['headroom'] is num
          ? (values['headroom'] as num).toDouble()
          : null,
      potentialHeadroom: values['potentialHeadroom'] is num
          ? (values['potentialHeadroom'] as num).toDouble()
          : null,
      decoderHdr: flag('decoderHdr'),
      nativeOutput: flag('nativeOutput'),
      nativeOutputCapable: values['nativeOutputCapable'] is bool
          ? values['nativeOutputCapable'] as bool
          : flag('nativeOutput'),
      nativeOutputActive: values['nativeOutputActive'] is bool
          ? values['nativeOutputActive'] as bool
          : flag('nativeOutput'),
      vulkan: flag('vulkan'),
      platformView: flag('platformView'),
      hcpp: flag('hcpp'),
      displayFormats: (values['displayFormats'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toSet(),
      decoderProfiles: (values['decoderProfiles'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toSet(),
      supportedInputFormats:
          (values['supportedInputFormats'] as List<Object?>? ?? const [])
              .whereType<String>()
              .toSet(),
      supportedOutputFormats:
          (values['supportedOutputFormats'] as List<Object?>? ?? const [])
              .whereType<String>()
              .toSet(),
      unsupportedReason: values['unsupportedReason'] as String?,
    );
  }
}

/// Serializes native HDR configuration and parameter readback transactions.
/// A stale request is checked before and after its asynchronous action, so it
/// cannot publish a result after a newer player or surface replaced it.
class HdrOutputTransactionGate {
  Future<void> _tail = Future<void>.value();

  Future<T?> run<T>({
    required bool Function() isCurrent,
    required Future<T> Function() action,
  }) {
    final run = _tail.then<T?>((_) async {
      if (!isCurrent()) return null;
      final result = await action();
      return isCurrent() ? result : null;
    });
    _tail = run.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return run;
  }
}

class HdrPlaybackDecision {
  final HdrOutputMode output;
  final String vo;
  final String hwdec;
  final String surface;
  final String reason;
  final bool usePlatformView;
  final bool useHcpp;
  final String sourceProcessing;
  final String outputEncoding;
  final bool dynamicMetadataApplied;

  const HdrPlaybackDecision({
    required this.output,
    required this.vo,
    required this.hwdec,
    required this.surface,
    required this.reason,
    this.usePlatformView = false,
    this.useHcpp = false,
    this.sourceProcessing = 'tone-map',
    this.outputEncoding = 'sdr',
    this.dynamicMetadataApplied = false,
  });

  bool get isNativeHdr => output == HdrOutputMode.nativeHdr;

  /// Identifies the native output carrier, excluding color-processing state.
  /// SDR and tone-mapped HDR share one texture, while HCPP uses a platform
  /// view. A color metadata update must not rebuild an unchanged carrier.
  String get outputTopologySignature =>
      useHcpp ? 'android-hcpp-platform-view' : 'flutter-texture';
}

/// Metadata submitted to a native video output. Native implementations must
/// return [HdrOutputResult.active] only after the OS color space and the
/// player surface have both accepted these values.
class HdrOutputConfiguration {
  final HdrTransfer transfer;
  final HdrPrimaries primaries;
  final HdrMatrix matrix;
  final int bitDepth;
  final String? codec;
  final String? profile;
  final String? hdrType;
  final String? surfaceId;
  final int surfaceGeneration;
  final String? dolbyVisionProfile;
  final bool rpuPresent;
  final bool baseLayerPresent;
  final bool enhancementLayerPresent;
  final DvEnhancementType dvEnhancement;
  final bool dynamicMetadataPresent;
  final Map<String, Object?> masteringMetadata;

  const HdrOutputConfiguration({
    required this.transfer,
    required this.primaries,
    this.matrix = HdrMatrix.unknown,
    this.bitDepth = 10,
    this.codec,
    this.profile,
    this.hdrType,
    this.surfaceId,
    this.surfaceGeneration = 0,
    this.dolbyVisionProfile,
    this.rpuPresent = false,
    this.baseLayerPresent = true,
    this.enhancementLayerPresent = false,
    this.dvEnhancement = DvEnhancementType.none,
    this.dynamicMetadataPresent = false,
    this.masteringMetadata = const <String, Object?>{},
  });

  Map<String, Object?> toMap() => {
    'transfer': transfer.name,
    'primaries': primaries.name,
    'matrix': matrix.name,
    'bitDepth': bitDepth,
    if (codec != null) 'codec': codec,
    if (profile != null) 'profile': profile,
    if (hdrType != null) 'hdrType': hdrType,
    if (dolbyVisionProfile != null) 'dolbyVisionProfile': dolbyVisionProfile,
    'rpuPresent': rpuPresent,
    'baseLayerPresent': baseLayerPresent,
    'enhancementLayerPresent': enhancementLayerPresent,
    'dvEnhancement': dvEnhancement.name,
    'dynamicMetadataPresent': dynamicMetadataPresent,
    'masteringMetadata': masteringMetadata,
    if (surfaceId != null) 'surfaceId': surfaceId,
    'surfaceGeneration': surfaceGeneration,
  };
}

class HdrOutputResult {
  final String backend;
  final String appliedColorSpace;
  final bool active;
  final String? failureReason;
  final List<String> supportedInputFormats;
  final List<String> supportedOutputFormats;
  final String sourceProcessing;
  final String outputEncoding;
  final bool dynamicMetadataApplied;

  const HdrOutputResult({
    this.backend = 'none',
    this.appliedColorSpace = 'sdr',
    this.active = false,
    this.failureReason,
    this.supportedInputFormats = const <String>[],
    this.supportedOutputFormats = const <String>[],
    this.sourceProcessing = 'tone-map',
    this.outputEncoding = 'sdr',
    this.dynamicMetadataApplied = false,
  });

  factory HdrOutputResult.fromMap(Map<Object?, Object?> values) =>
      HdrOutputResult(
        backend: values['backend'] as String? ?? 'none',
        appliedColorSpace: values['appliedColorSpace'] as String? ?? 'sdr',
        active: values['active'] == true,
        failureReason: values['failureReason'] as String?,
        supportedInputFormats:
            (values['supportedInputFormats'] as List<Object?>? ?? const [])
                .whereType<String>()
                .toList(),
        supportedOutputFormats:
            (values['supportedOutputFormats'] as List<Object?>? ?? const [])
                .whereType<String>()
                .toList(),
        sourceProcessing: values['sourceProcessing'] as String? ?? 'tone-map',
        outputEncoding: values['outputEncoding'] as String? ?? 'sdr',
        dynamicMetadataApplied: values['dynamicMetadataApplied'] == true,
      );
}

class HdrDecision {
  const HdrDecision._();

  /// Selects a safe output. Native HDR is never selected on a mere source
  /// metadata hint; all three native capability facts must be true.
  static HdrPlaybackDecision choose({
    required HdrMode mode,
    required HdrSourceMetadata source,
    required HdrCapabilities capabilities,
    String hwdec = 'auto',
    bool allowDolbyVisionNative = false,
  }) {
    if (!source.isHdr) {
      return HdrPlaybackDecision(
        output: HdrOutputMode.sdr,
        vo: 'gpu-next',
        hwdec: hwdec,
        surface: 'texture',
        reason: 'source-is-sdr',
      );
    }
    if (mode == HdrMode.off) {
      return HdrPlaybackDecision(
        output: HdrOutputMode.toneMappedSdr,
        vo: 'gpu-next',
        hwdec: hwdec,
        surface: 'texture',
        reason: 'disabled-by-user',
      );
    }
    // DV may enter ordinary HDR only as an explicit DV-to-HDR conversion. It
    // must not be described as native Dolby Vision metadata passthrough.
    final nativeSource =
        (allowDolbyVisionNative ||
            source.kind != HdrSourceKind.dolbyVision ||
            source.supportsConvertedHdrOutput) &&
        source.kind != HdrSourceKind.hdrVivid &&
        source.kind != HdrSourceKind.hdr10Plus &&
        source.hasNativeColorMetadata;
    if (source.kind == HdrSourceKind.dolbyVision &&
        source.isDolbyVisionP7 &&
        !allowDolbyVisionNative) {
      return HdrPlaybackDecision(
        output: HdrOutputMode.toneMappedSdr,
        vo: 'gpu-next',
        hwdec: hwdec,
        surface: 'texture',
        reason: source.baseLayerPresent
            ? 'dolby-vision-p7-hdr10-bl-fallback'
            : 'dolby-vision-p7-base-layer-missing',
        sourceProcessing: source.baseLayerPresent
            ? 'hdr10-base-layer-fallback'
            : 'unsupported',
        outputEncoding: 'sdr',
      );
    }
    if (nativeSource && capabilities.canNativeHdr) {
      return HdrPlaybackDecision(
        output: HdrOutputMode.nativeHdr,
        vo: 'gpu-next',
        hwdec: hwdec,
        surface: 'native-hdr',
        reason: 'display-decoder-and-output-ready',
        usePlatformView: capabilities.canHcpp,
        useHcpp: capabilities.canHcpp,
        sourceProcessing: source.kind == HdrSourceKind.dolbyVision
            ? 'dolby-vision-converted-to-hdr'
            : 'passthrough',
        outputEncoding: 'pq-or-hlg',
      );
    }
    // HCPP can be prepared before SurfaceControl has committed the stream's
    // dataspace, but that is not proof of native HDR output. Keep mpv in the
    // SDR tone-map mode until the native layer reports nativeOutput=true.
    if (nativeSource && capabilities.canNativeHdrCandidate) {
      return HdrPlaybackDecision(
        output: HdrOutputMode.toneMappedSdr,
        vo: 'gpu-next',
        hwdec: hwdec,
        surface: 'native-hdr-candidate',
        reason: 'hcpp-capabilities-awaiting-dataspace',
        usePlatformView: true,
        useHcpp: true,
        sourceProcessing: 'awaiting-native-output-proof',
      );
    }
    return HdrPlaybackDecision(
      output: HdrOutputMode.toneMappedSdr,
      vo: 'gpu-next',
      hwdec: hwdec,
      surface: 'texture',
      reason: capabilities.unsupportedReason ?? 'native-hdr-unavailable',
    );
  }
}
