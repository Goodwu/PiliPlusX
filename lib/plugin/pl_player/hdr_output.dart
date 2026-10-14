import 'package:flutter/foundation.dart';
import 'package:piliplus/plugin/pl_player/dovi_sniff.dart';
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
  /// （先 HDR 输出、HDR 中直出优先，见需求 3.4）。如需调整顺序，
  /// 在此构造 `HdrRoutingPolicy`，不新增设备判断。
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
  ///
  /// [dovi] 是对该 rendition 初始化段的 DOVI 配置记录嗅探结果
  /// （DV003：B 站 126 档以普通 `hvc1*` HEVC 串下发 DV 轨，profile 只能
  /// 来自容器记录）。仅当 codec 串推导不出 profile 且档位声明 DV 意图时
  /// 消费；解析失败/未知 profile 必须保持未知语义，不得猜测。
  static HdrSourceDescriptor? descriptorFromDash({
    int? quality,
    String? codec,
    DoviFacts? dovi,
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
      // DV003: the tier carries no profile in its codec string; a resolved
      // DOVI record sniffed from this rendition's own initialization segment
      // is the rendition's own declaration and may fill the profile facts.
      // Unrecognized profiles/compatibilities stay unknown (B1b), and the
      // Session still reviews container facts at open.
      final profile = dovi?.profile;
      if (profile != null) {
        switch (profile) {
          case 5:
            return HdrSourceDescriptor(
              codec: 'hevc',
              dynamicMetadata: HdrDynamicMetadata.dolbyVision,
              dvProfile: 5,
              dvCompatibilityId: 0,
              enhancementLayer: dovi!.elPresent,
            );
          case 8:
          case 10:
            // P8 base-layer signaling is declared by the compatibility id:
            // 4 → HLG, 1 → HDR10(PQ); other ids stay explicit and unknown.
            final compat = dovi!.compatibilityId;
            final transfer = switch (compat) {
              4 => 'hlg',
              1 => 'pq',
              _ => null,
            };
            return HdrSourceDescriptor(
              codec: 'hevc',
              transfer: transfer,
              primaries: transfer == null ? null : 'bt.2020',
              dynamicMetadata: HdrDynamicMetadata.dolbyVision,
              dvProfile: profile,
              dvCompatibilityId: compat,
              enhancementLayer: dovi.elPresent,
            );
        }
      }
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
    EffectiveVideoRouteOptions? options,
  }) => capabilities?.predict(
    descriptor,
    specification: specification,
    policy: policy,
    options: options,
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
      // C1 原生动态 HDR10+/Vivid 直通（§C1「原生动态 HDR」类，源名已携带
      // 制式）。通配臂保持对旧版依赖（无这两个枚举值）可编译；仅在实际
      // 执行命中时渲染，不冒充动态映射成功。
      _ => '原生动态 HDR',
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