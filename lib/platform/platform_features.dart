import 'platform_features_io.dart'
    if (dart.library.html) 'platform_features_web.dart'
    as impl;

/// Capabilities that may be exposed by the current Flutter target.
///
/// These are compile-time safe: the web implementation never imports
/// dart:io or a native plugin. UI code should use this instead of probing
/// platform libraries directly when deciding whether to show an action.
abstract final class PlatformFeatureSupport {
  static bool get isWeb => impl.isWeb;
  static bool get isAndroid => impl.isAndroid;
  static bool get isIOS => impl.isIOS;
  static bool get isMacOS => impl.isMacOS;
  static bool get isWindows => impl.isWindows;
  static bool get isLinux => impl.isLinux;

  static bool get offlineDownload => impl.offlineDownload;
  static bool get fileExport => impl.fileExport;
  static bool get tray => impl.tray;
  static bool get nativeWindow => impl.nativeWindow;
  static bool get backgroundAudio => impl.backgroundAudio;
  static bool get pictureInPicture => impl.pictureInPicture;
  static bool get screenshot => impl.screenshot;
  static bool get nativeHdr => impl.nativeHdr;
}
