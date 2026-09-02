import 'package:PiliPlus/plugin/pl_player/models/hdr.dart';
import 'package:PiliPlus/platform/platform_features.dart';
import 'package:flutter/services.dart';

abstract final class HdrAndroid {
  static const _channel = MethodChannel(
    'piliplusx/hdr_capabilities',
  );

  static Future<HdrCapabilities> probe({String? codec}) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'probe',
        <String, Object?>{'codec': codec},
      );
      return result == null
          ? HdrCapabilities(
              platform: _platformName,
              unsupportedReason: 'probe-returned-null',
            )
          : HdrCapabilities.fromMap(result);
    } on PlatformException catch (error) {
      return HdrCapabilities(
        platform: _platformName,
        unsupportedReason: 'probe-failed:${error.code}',
      );
    } on MissingPluginException {
      return HdrCapabilities(
        platform: _platformName,
        unsupportedReason: 'probe-not-implemented:$_platformName',
      );
    } on Object catch (error) {
      return HdrCapabilities(
        platform: _platformName,
        unsupportedReason: 'probe-failed:${error.runtimeType}',
      );
    }
  }

  static String get _platformName {
    if (PlatformFeatureSupport.isAndroid) return 'android';
    if (PlatformFeatureSupport.isIOS) return 'ios';
    if (PlatformFeatureSupport.isMacOS) return 'macos';
    if (PlatformFeatureSupport.isWindows) return 'windows';
    if (PlatformFeatureSupport.isLinux) return 'linux';
    return 'unknown';
  }

  static Future<bool> setWindowHdrMode({required bool hdr}) async {
    if (!PlatformFeatureSupport.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
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

  static Future<HdrOutputResult> configureOutput(
    HdrOutputConfiguration configuration,
  ) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'configureOutput',
        configuration.toMap(),
      );
      return result == null
          ? const HdrOutputResult(failureReason: 'configure-returned-null')
          : HdrOutputResult.fromMap(result);
    } on Object catch (error) {
      return HdrOutputResult(
        failureReason: 'configure-failed:${error.runtimeType}',
      );
    }
  }

  static Future<bool> resetOutput() async {
    try {
      return await _channel.invokeMethod<bool>('resetOutput') ?? false;
    } on Object {
      return false;
    }
  }
}
