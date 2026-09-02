import 'package:PiliPlus/platform/platform_features.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr.dart';
import 'package:flutter/services.dart';

/// Android-only Window and video-surface HDR operations.
abstract final class HdrAndroid {
  static Future<bool> setWindowHdrMode({required bool hdr}) async {
    if (!PlatformFeatureSupport.isAndroid) return false;
    try {
      return await const MethodChannel(
            'piliplusx/hdr_capabilities',
          ).invokeMethod<bool>(
            'setWindowHdrMode',
            <String, Object?>{'hdr': hdr},
          ) ??
          false;
    } on Object {
      return false;
    }
  }

  static Future<bool> setColorSpace({
    required int handle,
    required HdrTransfer transfer,
  }) async {
    if (!PlatformFeatureSupport.isAndroid) return false;
    final transferName = switch (transfer) {
      HdrTransfer.pq => 'pq',
      HdrTransfer.hlg => 'hlg',
      _ => 'sdr',
    };
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    // videoParams and SurfaceView attachment are asynchronous. Retry only
    // during the short creation window so an early callback does not turn a
    // valid HCPP surface into a false initialization failure.
    for (final delay in const [
      Duration.zero,
      Duration(milliseconds: 50),
      Duration(milliseconds: 100),
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
    ]) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      try {
        final applied = await channel.invokeMethod<bool>(
          'PlatformVideoView.SetColorSpace',
          {'handle': handle.toString(), 'transfer': transferName},
        );
        if (applied == true) return true;
      } on Object {
        // Keep trying while the native view is being attached. A final
        // failure is handled by the caller's SurfaceView/Texture fallback.
      }
    }
    return false;
  }
}
