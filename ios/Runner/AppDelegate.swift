import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "piliplusx/hdr_capabilities",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "resetOutput" {
        result(true)
        return
      }
      if call.method == "configureOutput" {
        result([
          "backend": "ios-cametalayer",
          "appliedColorSpace": "sdr",
          "active": false,
          "failureReason": "native-hdr-layer-not-integrated"
        ])
        return
      }
      guard call.method == "probe" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Keep the iOS backend fail-closed.  EDR probing is intentionally
      // omitted here because this SDK does not expose a stable HDR probe;
      // wide-gamut/P3 is not evidence of HDR output.
      let edr = false
      result([
        "platform": "ios",
        "nativeBackend": "none",
        "displayHdr": edr,
        "decoderHdr": false,
        "nativeOutput": false,
        "nativeOutputCapable": false,
        "nativeOutputActive": false,
        "toneMapping": true,
        "displayFormats": edr ? ["edr"] : [],
        "unsupportedReason": "native-hdr-layer-not-integrated"
      ])
    }
  }
}
