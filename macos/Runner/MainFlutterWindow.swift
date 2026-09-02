import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var hdrScreen: NSScreen?

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
    hdrScreen = screen ?? NSScreen.main
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
          "failureReason": "native-hdr-layer-not-integrated"
        ])
        return
      }
      guard call.method == "probe" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let activeScreen = self.hdrScreen ?? self.screen ?? NSScreen.main
      let edr = (activeScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
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

    // Keep capability probing tied to the screen that actually contains the
    // window. Moving between HDR and SDR displays must not leave stale EDR
    // state behind, even while native output remains fail-closed.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeScreenNotification,
      object: self, queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      self.hdrScreen = (notification.object as? NSWindow)?.screen ?? NSScreen.main
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.hdrScreen = self.screen ?? NSScreen.main
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
