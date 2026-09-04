import Cocoa
import FlutterMacOS

private final class HdrDisplayEventHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func emit() {
    eventSink?(nil)
  }
}

class MainFlutterWindow: NSWindow {
  private func applyOpaqueWindowAppearance() {
    // 恢复系统默认的不透明窗口背景
    self.isOpaque = true
    self.backgroundColor = .windowBackgroundColor

    // 正常显示标题栏时禁用透明效果
    if self.titleVisibility == .visible {
      self.titlebarAppearsTransparent = false
      self.styleMask.remove(.fullSizeContentView)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    // 先不显示窗口
    self.isReleasedWhenClosed = false
    self.contentViewController = flutterViewController
    self.setFrame(self.frame, display: true)

    applyOpaqueWindowAppearance()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "piliplusx/hdr_capabilities",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "resetOutput" {
        result(true)
        return
      }
      if call.method == "configureOutput" {
        result([
          "backend": "macos-cametalayer",
          "appliedColorSpace": "sdr",
          "active": false,
          "sourceProcessing": "tone-map",
          "outputEncoding": "sdr",
          "dynamicMetadataApplied": false,
          "supportedInputFormats": [],
          "supportedOutputFormats": ["sdr"],
          "failureReason": "native-hdr-layer-not-integrated"
        ])
        return
      }
      guard call.method == "probe" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let activeScreen = self.screen ?? NSScreen.main
      // `maximumExtendedDynamicRangeColorComponentValue` remains 1.0 until
      // some onscreen content requests EDR. Using it as a capability gate
      // creates a deadlock: HDR quality is disabled before HDR content can be
      // shown. The potential value answers whether this display supports EDR.
      let edr =
        (activeScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
      result([
        "platform": "macos",
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

    let displayEventHandler = HdrDisplayEventHandler()
    FlutterEventChannel(
      name: "piliplusx/hdr_display_changes",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setStreamHandler(displayEventHandler)

    // Keep capability probing tied to the screen that actually contains the
    // window. Moving between HDR and SDR displays must not leave stale EDR
    // state behind, even while native output remains fail-closed.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeScreenNotification,
      object: self, queue: .main
    ) { [weak self] notification in
      guard self != nil else { return }
      displayEventHandler.emit()
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      guard self != nil else { return }
      displayEventHandler.emit()
    }

    // 监听首帧渲染完成再显示窗口
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("io.flutter.embedding.engine.firstFrame"),
      object: flutterViewController.engine, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // window_manager 配置完成后恢复不透明样式
      self.applyOpaqueWindowAppearance()
      self.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    // macOS Flutter does not guarantee the Android-style firstFrame
    // notification above. Show the window immediately so a missing optional
    // notification cannot leave the app hidden/black; the callback still
    // reapplies the opaque style once the first frame is rasterized.
    super.awakeFromNib()
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
