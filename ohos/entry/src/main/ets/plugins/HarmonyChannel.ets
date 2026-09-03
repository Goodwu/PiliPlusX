import window from "@ohos.window";
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from "@ohos/flutter_ohos";

// import display from "@ohos.display";

export default class HarmonyChannel implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private lastWindow: window.Window | null = null;

  getUniqueClassName(): string {
    return "HarmonyChannel";
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "harmonyChannel");
    this.channel.setMethodCallHandler(this);
    // // 监听画面方向
    // display.on('change', () => {
    //   // 获取当前旋转角度
    //   let rotation = display.getDefaultDisplaySync().rotation;
    //   this.channel!.invokeMethod('onRotationChange', { 'rotation': rotation })
    // })
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
  }

  async csy(call: MethodCall) {
    this.lastWindow ??= await window.getLastWindow(getContext());
    return this.lastWindow.setSpecificSystemBarEnabled("status", call.argument("value"), true);
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    switch (call.method) {
      case "csy":
        result.success(await this.csy(call));
        break;
      case "setMiniWindowLandscape":
        const landscape: boolean = call.argument("landscape") ?? false;
        await this.setMiniWindowLandscape(landscape);
        result.success(true);
        break;
      case "autoRotateLandscape":
        await this.autoRotateLandscape();
        result.success(true);
        break;
      case "setWindowBrightness":
        const brightness: number = call.argument("value") ?? -1;
        this.lastWindow ??= await window.getLastWindow(getContext());
        await this.lastWindow.setWindowBrightness(brightness);
        result.success(true);
        break;
      // case 'setWindowLayoutFullScreen': {
      //   this.lastWindow ??= await window.getLastWindow(getContext())
      //   this.lastWindow.setWindowLayoutFullScreen(call.argument('fullScreen'));
      //   result.success(true);
      //   break;
      // }
      default:
        result.notImplemented();
        break;
    }
  }

  public onFloatingWindowChange(isFloatingWindow: boolean) {
    this.channel?.invokeMethod("onFloatingWindowChange", { isFloatingWindow: isFloatingWindow });
  }

  private async setMiniWindowLandscape(landscape: boolean) {
    this.lastWindow ??= await window.getLastWindow(getContext());
    if (landscape) {
      this.lastWindow.enableLandscapeMultiWindow();
    } else {
      this.lastWindow.disableLandscapeMultiWindow();
    }
  }

  async autoRotateLandscape() {
    this.lastWindow ??= await window.getLastWindow(getContext());
    this.lastWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE)
  }
}

/**
 * OHOS capability response is deliberately conservative until an OHOS
 * XComponent/NativeWindow HDR path is verified on a device.
 */
export class HdrCapabilitiesChannel implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return "HdrCapabilitiesChannel";
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      "piliplusx/hdr_capabilities"
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method == "resetOutput") {
      result.success(true);
      return;
    }
    if (call.method == "configureOutput") {
      result.success({
        "backend": "ohos-nativewindow",
        "appliedColorSpace": "sdr",
        "active": false,
        "sourceProcessing": "tone-map",
        "outputEncoding": "sdr",
        "dynamicMetadataApplied": false,
        "supportedInputFormats": [],
        "supportedOutputFormats": ["sdr"],
        "failureReason": "ohos-nativewindow-hdr-not-integrated",
      });
      return;
    }
    if (call.method != "probe") {
      result.notImplemented();
      return;
    }
    result.success({
      "platform": "ohos",
      "nativeBackend": "none",
      "displayHdr": false,
      "decoderHdr": false,
      "nativeOutput": false,
      "nativeOutputCapable": false,
      "nativeOutputActive": false,
      "toneMapping": true,
      "displayFormats": [],
      "decoderProfiles": [],
      "unsupportedReason": "ohos-hdr-capability-not-proven",
    });
  }
}
