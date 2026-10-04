import 'package:media_kit/media_kit.dart';
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

  /// 最近一次能力快照（选档用）。由 [queryCapabilities] 统一经
  /// media-kit 公开 API `HdrCapabilities.query(player:)` 刷新：有 Player
  /// 时探测 mpv fork 的 P5 管线；无 Player（首个视频页尚未建播放器）时
  /// P5 管线保守按缺失处理（P5 档预测回落 SDR；P8.4/HDR10/HLG/SDR 预测
  /// 不受影响）。拿到 Player 后应重新查询刷新 P5 结论。
  static HdrCapabilities? lastCapabilities;

  /// 开播前能力查询（R1.1）。[player] 可空直传 media-kit 公开 API，
  /// 不再手工读插件通道兜底。
  static Future<HdrCapabilities?> queryCapabilities({Player? player}) async {
    try {
      lastCapabilities = await HdrCapabilities.query(player: player);
      return lastCapabilities;
    } on Object {
      return lastCapabilities;
    }
  }

  /// 由 DASH codec 字符串与清晰度档位构造源描述（R2.3 hint）。
  /// 纯跨平台映射：只看 codec 串与 Bilibili 档位编号，无任何设备判断。
  /// 返回 null 表示 SDR/未知档，不给 hint（会话先按 SDR 打开，解码器复核）。
  static HdrSourceDescriptor? descriptorFromDash({
    int? quality,
    String? codec,
  }) {
    final normalized = codec?.toLowerCase() ?? '';
    if (normalized.startsWith('dvh1') || normalized.startsWith('dvhe')) {
      final parts = normalized.split('.');
      final profile = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (profile == 5) {
        // DV P5：基础层 IPT 色彩，所有路由依赖 dovi rescale 管线。
        return const HdrSourceDescriptor(
          codec: 'hevc',
          dynamicMetadata: HdrDynamicMetadata.dolbyVision,
          dvProfile: 5,
          dvCompatibilityId: 0,
          enhancementLayer: false,
        );
      }
      // 其余 DV（含 P8）：Bilibili DV 档当前为 P8.4（HLG 基础层）。
      // mpv 不暴露兼容 ID，按基础层传输函数推断 8.4（库内同规则）；
      // hint 不符时由会话解码器复核纠正（最多一次原位重建）。
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
    if (quality == 126 &&
        (normalized.contains('dolby') || normalized.contains('dv'))) {
      // DV 档但 codec 串缺 profile：保守按 P5（hint 只影响开播路由的
      // 预配置；hint 错误由会话解码器复核的单次重建纠正，保守取 P5
      // 避免任何忽略 RPU 的路由被错误 hint 选中）。
      return const HdrSourceDescriptor(
        codec: 'hevc',
        dynamicMetadata: HdrDynamicMetadata.dolbyVision,
        dvProfile: 5,
        dvCompatibilityId: 0,
        enhancementLayer: false,
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
    HdrCapabilities? capabilities,
  }) {
    final caps = capabilities ?? lastCapabilities;
    if (caps == null) return null;
    return caps.predict(descriptor, policy: policy);
  }

  /// 「片源与显示能力是否一致」的 App 决策：预测可呈现（能开播且呈现为
  /// HDR）才请求 HDR 档，否则回落 SDR 档。
  static bool isHdrPresentable(HdrRoutePrediction? prediction) {
    return prediction != null &&
        prediction.playable &&
        prediction.presentation == HdrPresentation.nativeHdr;
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
