#include "flutter_window.h"

#include <dxgi1_6.h>
#include <wrl.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  hdr_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "piliplusx/hdr_capabilities",
      &flutter::StandardMethodCodec::GetInstance());
  hdr_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "resetOutput") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "configureOutput") {
          flutter::EncodableMap response;
          response[flutter::EncodableValue("backend")] =
              flutter::EncodableValue("windows-dxgi");
          response[flutter::EncodableValue("appliedColorSpace")] =
              flutter::EncodableValue("sdr");
          response[flutter::EncodableValue("active")] =
              flutter::EncodableValue(false);
          response[flutter::EncodableValue("sourceProcessing")] =
              flutter::EncodableValue("tone-map");
          response[flutter::EncodableValue("outputEncoding")] =
              flutter::EncodableValue("sdr");
          response[flutter::EncodableValue("dynamicMetadataApplied")] =
              flutter::EncodableValue(false);
          response[flutter::EncodableValue("supportedInputFormats")] =
              flutter::EncodableValue(flutter::EncodableList{});
          response[flutter::EncodableValue("supportedOutputFormats")] =
              flutter::EncodableValue(flutter::EncodableList{
                  flutter::EncodableValue("sdr")});
          response[flutter::EncodableValue("failureReason")] =
              flutter::EncodableValue("native-swapchain-not-integrated");
          result->Success(flutter::EncodableValue(std::move(response)));
          return;
        }
        if (call.method_name() != "probe") {
          result->NotImplemented();
          return;
        }

        bool hdr_active = false;
        std::vector<flutter::EncodableValue> formats;
        const HWND window = GetHandle();
        const HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);

        Microsoft::WRL::ComPtr<IDXGIFactory6> factory;
        if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
          for (UINT adapter_index = 0;; ++adapter_index) {
            Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
            if (factory->EnumAdapters1(adapter_index, &adapter) == DXGI_ERROR_NOT_FOUND) {
              break;
            }
            for (UINT output_index = 0;; ++output_index) {
              Microsoft::WRL::ComPtr<IDXGIOutput> output;
              if (adapter->EnumOutputs(output_index, &output) == DXGI_ERROR_NOT_FOUND) {
                break;
              }
              DXGI_OUTPUT_DESC desc = {};
              if (FAILED(output->GetDesc(&desc)) ||
                  MonitorFromRect(&desc.DesktopCoordinates,
                                  MONITOR_DEFAULTTONEAREST) != monitor) {
                continue;
              }
              Microsoft::WRL::ComPtr<IDXGIOutput6> output6;
              if (SUCCEEDED(output.As(&output6))) {
                DXGI_OUTPUT_DESC1 desc1 = {};
                if (SUCCEEDED(output6->GetDesc1(&desc1))) {
                  if (desc1.ColorSpace ==
                      DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020) {
                    hdr_active = true;
                    formats.emplace_back("PQ");
                  }
                  if (desc1.BitsPerColor >= 10) {
                    formats.emplace_back("10-bit");
                  }
                }
              }
              break;
            }
            if (hdr_active) break;
          }
        }

        flutter::EncodableMap response;
        response[flutter::EncodableValue("platform")] =
            flutter::EncodableValue("windows");
        response[flutter::EncodableValue("nativeBackend")] =
            flutter::EncodableValue("none");
        response[flutter::EncodableValue("displayHdr")] =
            flutter::EncodableValue(hdr_active);
        response[flutter::EncodableValue("decoderHdr")] =
            flutter::EncodableValue(false);
        response[flutter::EncodableValue("nativeOutput")] =
            flutter::EncodableValue(false);
        response[flutter::EncodableValue("nativeOutputCapable")] =
            flutter::EncodableValue(false);
        response[flutter::EncodableValue("nativeOutputActive")] =
            flutter::EncodableValue(false);
        response[flutter::EncodableValue("toneMapping")] =
            flutter::EncodableValue(true);
        response[flutter::EncodableValue("displayFormats")] =
            flutter::EncodableValue(flutter::EncodableList(formats));
        response[flutter::EncodableValue("unsupportedReason")] = hdr_active
            ? flutter::EncodableValue("windows-native-swapchain-not-integrated")
            : flutter::EncodableValue("windows-hdr-output-not-active");
        result->Success(flutter::EncodableValue(std::move(response)));
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // flutter_controller_->engine()->SetNextFrameCallback([&]() {
  //   this->Show();
  // });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  hdr_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
