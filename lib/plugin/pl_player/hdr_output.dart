import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Android HDR 选档与展示接入层（S12，验收 A7/A8）。
///
/// 本文件只允许出现三类代码（A8 红线）：
/// 1. 调用 media-kit R1 查询/predict 选择档位；
/// 2. 跨平台策略偏好常量；
/// 3. 路由报告（report.actual）到展示文案的映射与事件消费。
/// 设备判断（SDK/指纹/输出拓扑选择）一律不在此出现，全部由
/// `HdrVideoSession` 会话编排。
abstract final class HdrOutputSelector {
  /// 跨平台策略偏好入口（R2.2 可选覆写）。默认使用库默认顺序
  /// （先 HDR 输出、HDR 中直出优先，见需求 3.4）。如需调整顺序或开启
  /// `allowExperimental`，在此构造 `HdrRoutingPolicy`，不新增设备判断。
  static const HdrRoutingPolicy policy = HdrRoutingPolicy.defaults;

  /// Query one explicit output target before creating a Player. A failure is
  /// unknown for THIS request; never reuse a previous display/source snapshot.
  static Future<VideoRouteCapabilities?> queryCapabilities({
    required VideoOutputTarget target,
    Iterable<VideoSourceSpec> sources = const [],
  }) async {
    try {
      return await VideoRouteCapabilities.query(
        target: target,
        sources: sources,
      );
    } on Object catch (error) {
      debugPrint('Video route capability query failed: ${error.runtimeType}');
      return null;
    }
  }

  /// 由 DASH codec 字符串与清晰度档位构造源描述（R2.3 hint）。
  /// 纯跨平台映射：只看 codec 串与 Bilibili 档位编号，无任何设备判断。
  /// 返回 null 表示 SDR/未知档，不给 hint（会话先按 SDR 打开，解码器复核）。
  static HdrSourceDescriptor? descriptorFromDash({
    int? quality,
    String? codec,
  }) {
    final normalized = codec?.trim().toLowerCase() ?? '';
    if (normalized.startsWith('dvh1') || normalized.startsWith('dvhe')) {
      final parts = normalized.split('.');
      final profile = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (profile == 5) {
        // P5 hint: native DV or a correct RPU-preserving processing path.
        return const HdrSourceDescriptor(
          codec: 'hevc',
          dynamicMetadata: HdrDynamicMetadata.dolbyVision,
          dvProfile: 5,
          dvCompatibilityId: 0,
          enhancementLayer: false,
        );
      }
      if (profile == 8) {
        // Retain the existing Bilibili P8.4 provider hint for a declared P8
        // codec only. This is not a general DV profile/compatibility rule;
        // actual container facts must still be reviewed by the Session.
        return const HdrSourceDescriptor(
          codec: 'hevc',
          transfer: 'hlg',
          primaries: 'bt.2020',
          dynamicMetadata: HdrDynamicMetadata.dolbyVision,
          dvProfile: 8,
          dvCompatibilityId: 4,
          enhancementLayer: false,
        );
      }
      // Preserve the parsed profile, if any; never manufacture P5/P8.4 or
      // a single-layer flag for missing, malformed or another DV profile.
      return HdrSourceDescriptor(
        codec: 'hevc',
        dynamicMetadata: HdrDynamicMetadata.dolbyVision,
        dvProfile: profile,
      );
    }
    if (quality == 126) {
      // The DV tier identifies metadata intent, not its profile, base-layer
      // encoding or layer structure. Unknown must remain unknown at selection.
      return const HdrSourceDescriptor(
        dynamicMetadata: HdrDynamicMetadata.dolbyVision,
      );
    }
    if (quality == 129 || normalized.contains('vivid')) {
      return const HdrSourceDescriptor(
        codec: 'hevc',
        dynamicMetadata: HdrDynamicMetadata.hdrVivid,
      );
    }
    if (quality == 125) {
      // HDR10 档：PQ/BT.2020 基础层。
      return const HdrSourceDescriptor(
        codec: 'hevc',
        transfer: 'pq',
        primaries: 'bt.2020',
        enhancementLayer: false,
      );
    }
    return null;
  }

  /// 选档预测（R1.2）：同一 planner 同时用于执行，预测与执行同源。
  static HdrRoutePrediction? predict({
    required HdrSourceDescriptor descriptor,
    required VideoSourceSpec specification,
    required VideoRouteCapabilities? capabilities,
  }) => capabilities?.predict(
    descriptor,
    specification: specification,
    policy: policy,
  );

  /// 「片源与显示能力是否一致」的 App 决策：预测可呈现（能开播且呈现为
  /// HDR 或原生杜比视界）才请求 HDR 档，否则回落 SDR 档。
  /// `nativeDolbyVision` 是库侧 DV 成熟度提升后的默认呈现
  /// （nativeDV 直通），与 `nativeHdr` 同属可呈现 HDR 输出。
  static bool isHdrPresentable(HdrRoutePrediction? prediction) {
    return prediction != null &&
        prediction.playable &&
        (prediction.presentation == HdrPresentation.nativeHdr ||
            prediction.presentation == HdrPresentation.nativeDolbyVision);
  }

  /// report.actual 到播放信息文案的映射（R4.2 示例：
  /// 「杜比视界 P8.4 · HLG 直出」「杜比视界 P5 · RPU 重建 PQ」）。
  static String? routeLabel(HdrOutputReport report) {
    final actual = report.actual;
    if (actual == null) return null;
    final source = report.source ?? const HdrSourceDescriptor();
    final sourceName = switch (HdrSourceClass.of(source)) {
      HdrSourceClass.dvP5 => '杜比视界 P5',
      HdrSourceClass.dvP81 => '杜比视界 P8.1',
      HdrSourceClass.dvP82 => '杜比视界 P8.2',
      HdrSourceClass.dvP84 => '杜比视界 P8.4',
      HdrSourceClass.dvP7 => '杜比视界 P7',
      HdrSourceClass.hdr10 => 'HDR10',
      HdrSourceClass.hlg => 'HLG',
      HdrSourceClass.hdrVivid => 'HDR Vivid',
      HdrSourceClass.hdr10Plus => 'HDR10+',
      HdrSourceClass.dvP10 => '杜比视界 P10',
      HdrSourceClass.dvUnknown => '杜比视界（源信息未确定）',
      HdrSourceClass.sdr => 'SDR',
    };
    final transferName = switch (actual.outputTransfer) {
      HdrOutputTransfer.pq => 'PQ',
      HdrOutputTransfer.hlg => 'HLG',
      HdrOutputTransfer.dolbyVision => '杜比视界',
      HdrOutputTransfer.sdr => 'SDR',
    };
    final routeName = switch (actual.strategy) {
      HdrStrategy.baseLayerDirect => '$transferName 直出',
      HdrStrategy.baseLayerConvert => '转 $transferName 输出',
      HdrStrategy.metadataReshape => 'RPU 重建 $transferName',
      HdrStrategy.toneMapSdr => 'tone-map SDR',
      HdrStrategy.sdrDirect => 'SDR 直出',
      HdrStrategy.nativeDolbyVision => '原生杜比视界',
    };
    if (actual.presentation == HdrPresentation.sdr) {
      return routeName;
    }
    return '$sourceName · $routeName';
  }

  /// dvProfile 统计日志（每次播放一行 key=value，供默认顺序与样片优先级
  /// 决策）。仅使用 report 中的事实，无设备判断。
  static String dvProfileStatLine(
    HdrOutputReport report, {
    int? quality,
    String? codec,
  }) {
    final source = report.source;
    return 'HDR dvProfile stats: '
        'dvProfile=${source?.dvProfile ?? 'none'}, '
        'compatId=${source?.dvCompatibilityId ?? 'unknown'}, '
        'strategy=${report.actual?.strategy.name ?? 'unknown'}, '
        'presentation=${report.actual?.presentation.name ?? 'unknown'}, '
        'confidence=${report.prediction?.confidence.name ?? 'unknown'}, '
        'degrade=${report.degradeReason?.name ?? 'none'}, '
        'quality=${quality ?? 'unknown'}, '
        'codec=${codec ?? 'unknown'}';
  }
}
