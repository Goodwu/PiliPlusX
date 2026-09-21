import Cocoa
import Darwin
import FlutterMacOS
import VideoToolbox

// Keep these declarations opaque: libavcodec is embedded by media-kit rather
// than linked by the Runner target. The two public FFmpeg functions below let
// us query the exact decoder binary that mpv will use at runtime.
private struct FFmpegHardwareConfig {
  let pixelFormat: Int32
  let methods: Int32
  let deviceType: Int32
}

private typealias FFmpegFindDecoder = @convention(c) (
  UnsafePointer<CChar>
) -> UnsafeRawPointer?
private typealias FFmpegGetHardwareConfig = @convention(c) (
  UnsafeRawPointer,
  Int32
) -> UnsafeRawPointer?

private let ffmpegVideoToolboxDeviceType: Int32 = 6

private func bundledFFmpegSupportsVideoToolboxDecoder(
  named decoderName: String
) -> Bool? {
  guard
    let frameworksPath = Bundle.main.privateFrameworksPath,
    let handle = dlopen(
      URL(fileURLWithPath: frameworksPath)
        .appendingPathComponent("libavcodec.dylib")
        .path,
      RTLD_LAZY
    ),
    let findDecoderSymbol = dlsym(handle, "avcodec_find_decoder_by_name"),
    let getHardwareConfigSymbol = dlsym(handle, "avcodec_get_hw_config")
  else {
    return nil
  }
  let findDecoder = unsafeBitCast(findDecoderSymbol, to: FFmpegFindDecoder.self)
  let getHardwareConfig = unsafeBitCast(
    getHardwareConfigSymbol,
    to: FFmpegGetHardwareConfig.self
  )
  return decoderName.withCString { name in
    guard let decoder = findDecoder(name) else {
      return false
    }
    var index: Int32 = 0
    while let configuration = getHardwareConfig(decoder, index) {
      let hardwareConfig = configuration
        .assumingMemoryBound(to: FFmpegHardwareConfig.self)
        .pointee
      if hardwareConfig.deviceType == ffmpegVideoToolboxDeviceType {
        return true
      }
      index += 1
    }
    return false
  }
}

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
      if call.method == "probeVideoDecode" {
        let arguments = call.arguments as? [String: Any]
        let codec = arguments?["codec"] as? String ?? ""
        let width = arguments?["width"] as? Int ?? 0
        let height = arguments?["height"] as? Int ?? 0
        guard width > 0, height > 0 else {
          result(["codec": codec, "width": width, "height": height,
                  "supported": false, "reason": "invalid-track-size"])
          return
        }
        let normalized = codec.lowercased()
        let codecType: CMVideoCodecType?
        let ffmpegDecoderName: String?
        if normalized.hasPrefix("av01") {
          if #available(macOS 11.0, *) {
            codecType = kCMVideoCodecType_AV1
            ffmpegDecoderName = "av1"
          } else {
            codecType = nil
            ffmpegDecoderName = nil
          }
        } else if normalized.hasPrefix("hvc1") || normalized.hasPrefix("hev1") {
          codecType = kCMVideoCodecType_HEVC
          ffmpegDecoderName = "hevc"
        } else if normalized.hasPrefix("avc1") || normalized.hasPrefix("avc3") {
          codecType = kCMVideoCodecType_H264
          ffmpegDecoderName = "h264"
        } else {
          codecType = nil
          ffmpegDecoderName = nil
        }
        guard let codecType, let ffmpegDecoderName else {
          result(["codec": codec, "width": width, "height": height,
                  "supported": false, "reason": "unsupported-codec"])
          return
        }
        if #available(macOS 11.0, *) {
          // A system codec-family answer alone is insufficient: the bundled
          // FFmpeg may omit that codec's VideoToolbox hwaccel (for example,
          // an AV1 stream). Check the same libavcodec binary used by mpv
          // first, then ask the OS whether current hardware supports it.
          guard let ffmpegSupportsDecoder = bundledFFmpegSupportsVideoToolboxDecoder(
            named: ffmpegDecoderName
          ) else {
            result(["codec": codec, "width": width, "height": height,
                    "supported": false,
                    "reason": "bundled-hwdec-probe-unavailable"])
            return
          }
          guard ffmpegSupportsDecoder else {
            result(["codec": codec, "width": width, "height": height,
                    "supported": false,
                    "reason": "bundled-videotoolbox-decoder-unavailable"])
            return
          }
          let supported = VTIsHardwareDecodeSupported(codecType)
          result(["codec": codec, "width": width, "height": height,
                  "supported": supported,
                  "reason": supported ? "hardware-decode-supported" : "hardware-decode-unavailable"])
        } else {
          result(["codec": codec, "width": width, "height": height,
                  "supported": false, "reason": "videotoolbox-probe-unavailable"])
        }
        return
      }
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
      let headroom = activeScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
      let potentialHeadroom =
        activeScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
      // `maximumExtendedDynamicRangeColorComponentValue` remains 1.0 until
      // some onscreen content requests EDR. Using it as a capability gate
      // creates a deadlock: HDR quality is disabled before HDR content can be
      // shown. The potential value answers whether this display supports EDR.
      let edr =
        (activeScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
      result([
        "platform": "macos",
        "nativeBackend": "cametal-layer",
        "displayHdr": edr,
        "headroom": headroom,
        "potentialHeadroom": potentialHeadroom,
        "decoderHdr": false,
        "nativeOutput": false,
        // The media-kit native-surface plugin owns the actual output. This
        // app channel only proves that the window's display can attempt EDR;
        // activation remains false until the native layer reports a float
        // frame and a successful HDR configuration.
        "nativeOutputCapable": edr,
        "nativeOutputActive": false,
        "toneMapping": true,
        "displayFormats": edr ? ["edr"] : [],
        "supportedOutputFormats": edr ? ["extended-linear-bt2020"] : [],
        "unsupportedReason": edr ? "native-surface-awaiting-frame" : "display-edr-unavailable"
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
