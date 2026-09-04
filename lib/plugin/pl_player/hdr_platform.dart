import 'package:PiliPlus/platform/platform_features.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr.dart';
import 'package:flutter/services.dart';

/// Cross-platform HDR capability and output lifecycle channel.
///
/// Platform implementations must fail closed: an absent or failed native
/// endpoint reports inactive output instead of being interpreted as HDR.
abstract final class HdrPlatform {
  static const _channel = MethodChannel('piliplusx/hdr_capabilities');
  static const _displayChanges = EventChannel('piliplusx/hdr_display_changes');

  static Stream<void> get displayChanges =>
      _displayChanges.receiveBroadcastStream().map((_) {});

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

  static String get _platformName {
    if (PlatformFeatureSupport.isAndroid) return 'android';
    if (PlatformFeatureSupport.isIOS) return 'ios';
    if (PlatformFeatureSupport.isMacOS) return 'macos';
    if (PlatformFeatureSupport.isWindows) return 'windows';
    if (PlatformFeatureSupport.isLinux) return 'linux';
    if (PlatformFeatureSupport.isOhos) return 'ohos';
    if (PlatformFeatureSupport.isWeb) return 'web';
    return 'unknown';
  }
}
