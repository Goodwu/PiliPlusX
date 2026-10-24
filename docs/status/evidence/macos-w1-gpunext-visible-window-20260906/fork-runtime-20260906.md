# macOS W1 fork candidate runtime evidence — 2026-09-06

## Scope

This is a macOS-only candidate check. It does not modify or validate the OHOS emulator
path. The OHOS emulator constraint remains software decode and RGBA display.

## Build

- Source tree: `/Users/wuweiwei1/src/ohos-native-build/mpv`
- Source revision: `6edeee0` (`feat: ohos support`), dirty only in
  `video/out/mac_common.swift` and `video/out/vulkan/context_mac.m`
- Build directory: `/tmp/mpv-macos-gpunext-embedded`
- Relevant configuration: `libmpv=true`, `cocoa=enabled`, `swift-build=enabled`,
  `vulkan=enabled`, `gl=disabled`
- Artifact: `/tmp/mpv-macos-gpunext-embedded/libmpv.dylib`
- Artifact architecture: arm64
- Artifact SHA-256 after resize fix: `7e2a4189b3c088ae9473e6d04dad341ebf86c2e07ad877a14d346db318e8e164`

The first GL-enabled build stopped at an existing libplacebo API mismatch in
`video/out/vo_gpu_next.c`; that failure was isolated by disabling GL. It was not treated
as evidence against the external-view patch.

## Runtime

The artifact was copied only into the isolated
`/Users/wuweiwei1/src/media-kit/media_kit_test/build/.../media_kit_test.app` framework,
then the app was ad-hoc re-signed. The stock binary was preserved at
`/tmp/media-kit-test-stock-mpv-20260906.dylib`.

Observed:

```text
NativeWindow.Attach ... result=["attached": true, ... "capable": true]
NativeWindow.Frame ... width: 1280.0, height: 720.0
NativeWindow.Bind: bound=true
```

The Flutter main window visibly contained the moving BT.709 control clip. A window-list
query for the app process returned only the main `media_kit_test` window; the separate mpv
window seen with stock mpv 0.41 was absent.

## Decision

The first run exposed a backing-scale/drawable-size defect: the video occupied roughly half
the target view. The candidate was then changed to accept external-view resize events and to
set the layer drawable size in backing pixels. The second run displayed the moving control
clip at the full 16:9 target size with expected letterboxing; the app process still had only
the main Flutter window. This proves the candidate can load, bind an external NSView, resize
the drawable, and produce visible gpu-next pixels in the Flutter host.

It does not yet prove production readiness: full resize, detach, and lifecycle behavior are
still open. HDR/Dolby Vision was not tested in this run.

A follow-up lifecycle run observed a native view deinit/init transition (token 1 to token 2),
but the host window remained `800x632`; the fullscreen shortcut did not produce a measurable
resize. A coordinate-based resize attempt could not be acquired reliably by the UI harness,
so no resize pass is claimed. The test app was stopped and its stock libmpv binary restored.

Next gate: verify resize and detach over repeated lifecycle operations, then begin HDR/DV
tests.

To make that gate repeatable, the isolated test host now has a macOS-only
`media_kit_test/window` MethodChannel and an AppBar resize button that requests `800x632`
and `640x520`. `flutter build macos --debug --no-pub` passed and `flutter analyze --no-pub`
reported only the host's existing 14 info-level lints. The channel was not counted as runtime
evidence in this run because the UI harness could not reacquire the app window after launch.

## Repeatable resize run

The isolated host was rebuilt with `--dart-define=MEDIA_KIT_AUTO_RESIZE=true`. After the
local control clip started, the test-only MethodChannel requested a content size of
`640x520`. The native channel returned a frame of `640x552` (32 px title-bar height), and an
independent `CGWindowList` query for the current process reported:

```text
kCGWindowBounds: Width = 640; Height = 552
```

The same run logged:

```text
MPVPROP vo=gpu-next
MPVPROP hwdec-current=videotoolbox
AUTO_WINDOW_RESIZE requested=640.0x520.0 result={height: 552.0, width: 640.0}
```

The captured window remained a single Flutter window and still contained the moving control
clip. Screenshot SHA-256:
`275a4e724cd718ae9473e6d04dad341ebf86c2e07ad877a14d346db318e8e164`.
Artifact: [fork-auto-resize-640x552-20260906.png](./fork-auto-resize-640x552-20260906.png).

This closes the initial resize proof for the fork candidate. Repeated resize, detach, and
destroy/recreate lifecycle proof remain open. The final app binary was restored to stock
libmpv after capture.

## Detach run

Using the same auto-resize host mode, the test disposed the player after the resize. The
runtime log contained:

```text
MpvWindowView macOS deinit handle=... generation=1 token=1
NativeSurfaceViewFactory macOS released handle=...
NativeWindow.Detach handle=... generation=1 result=[... "detached": true ...]
AUTO_PLAYER_DISPOSE completed
```

After detach, `CGWindowList` for the process still contained only one `media_kit_test`
window, now `640x552`; no mpv-owned child window remained. This closes the single dispose /
detach proof. It does not yet prove repeated destroy/recreate, reattach to a new generation,
or the full Flutter navigation lifecycle.

## Destroy/recreate run

The auto lifecycle host then rebuilt the player page after the first dispose. The same process
logged the second attach sequence:

```text
AUTO_LIFECYCLE_RECREATE generation=2
MpvWindowView macOS init handle=... token=2
NativeWindow.Attach handle=... token=2 ... "capable": true
NativeWindow.Bind: bound=true
MPVPROP vo=gpu-next
MPVPROP hwdec-current=videotoolbox
AUTO_WINDOW_RESIZE requested=640.0x520.0 result={height: 552.0, width: 640.0}
MpvWindowView macOS deinit handle=... token=2
NativeWindow.Detach handle=... "detached": true
AUTO_PLAYER_DISPOSE completed
```

The first cycle used token 1 and a different native handle; the recreated cycle used token 2
and a new native handle, then rendered and detached again. This closes the isolated SDR
destroy/recreate and reattach proof. User navigation, background/foreground, and HDR/Dolby
Vision acceptance remain open.

## HDR10/PQ source run

The same isolated fork artifact was run with
`/Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4`. `ffprobe` identifies the
input as HEVC Main 10, P010, BT.2020, and SMPTE ST 2084 PQ. Runtime evidence included:

```text
VIDEOPARAMS ... pixelformat: p010 ... colormatrix: bt.2020-ncl ... primaries: bt.2020 ... gamma: pq
MPVPROP vo=gpu-next
MPVPROP hwdec-current=videotoolbox
MPVPROP video-format=hevc
MPVPROP video-params={... "pixelformat":"videotoolbox", "hw-pixelformat":"p010", ... "gamma":"pq" ...}
```

The PQ frame was visible inside the Flutter window and the resize/detach/recreate sequence
remained operational. However, the native output report still showed `active=false` and
`headroom=1.0`; no native EDR/high-headroom evidence was obtained. This proves PQ input,
HEVC decode, and gpu-next processing can run through the fork candidate, not that macOS
native HDR output is active. The captured PQ screenshot is
[fork-pq-auto-resize-640x552-20260906.png](./fork-pq-auto-resize-640x552-20260906.png),
SHA-256 `0fc82c0dfb374ef012f257b31e203a30d14a6858aaf4ae7654c81516c28a467f`.

No confirmed Dolby Vision input was available in this run; Dolby Vision remains unverified.

## HDR output-layer candidate run

The fork was then rebuilt after adding a macOS external-layer HDR configuration candidate:
for PQ/HLG target parameters it would set the external `CAMetalLayer` colorspace to
`itur_2100_PQ` and enable `wantsExtendedDynamicRangeContent`. The helper was called during
initialization, reconfiguration, and immediately before swap/present. The rebuilt artifact
was arm64 with SHA-256
`517f9972672db4359a01dcb0f620416156026f613135aa3f78607cd065509120`.

The PQ run still produced valid source and renderer evidence, but both lifecycle generations
logged:

```text
mpv external output HDR=false wantsEDR=false colorspace=nil
```

No `HDR=true` / `wantsEDR=true` transition was observed, including the second attach after
destroy/recreate. The candidate therefore did not establish that gpu-next's target color
parameters reached this macOS backend at the point where the external layer is configured.
The native-surface report remained `active=false`, `headroom=1.0`; no native EDR/highlight
proof was obtained. This is a failed diagnostic candidate, not evidence that PQ decode or
gpu-next is unavailable: the same run still showed P010/BT.2020/PQ, VideoToolbox, and
`vo=gpu-next`.

The isolated test app was stopped and its embedded stock libmpv was restored; the restored
framework SHA-256 is
`5d6e83ee94f35eff70d674e4b86ee4c00ffe36b5656ddbbdb562174f7b2c85d7`.

## Explicit HDR target follow-up

The previous result was narrowed with a W1-only change: before the experimental native-window
output is mounted, the opt-in test path sets `target-prim=bt.2020` and `target-trc=pq`.
This does not change the production default, OHOS, or the existing Darwin native-surface path.

With that explicit target, the same PQ input produced:

```text
mpv external output HDR=true wantsEDR=true colorspace=ITUR_2100_PQ (Rec. ITU-R BT.2100 PQ)
MPVPROP vo=gpu-next
MPVPROP hwdec-current=videotoolbox
MPVPROP video-params={... "pixelformat":"videotoolbox", "hw-pixelformat":"p010", ... "gamma":"pq" ...}
```

This corrects the prior diagnosis: `target_params` was available after the first rendered
frame, and the false result was caused by the W1 path leaving mpv's output target at its
default SDR policy. Explicit target selection reaches the fork's external-layer callback.

This still does not close the HDR gate. The run did not independently establish AppKit
`headroom > 1`, compositor activation, or a visible high-highlight comparison. The
`wantsEDR=true`/PQ colorspace log is configuration and renderer evidence only. The second
auto-recreated cycle did not provide a complete equivalent HDR attach log, so repeated HDR
lifecycle behavior remains open.

The app was again stopped and the embedded stock libmpv restored; its SHA-256 was
`5d6e83ee94f35eff70d674e4b86ee4c00ffe36b5656ddbbdb562174f7b2c85d7`.

## Extended-linear / metadata A-B

Because the existing working native-surface contract uses extended-linear BT.2020 rather
than PQ code values in its `rgba16Float` layer, the W1-only experiment was repeated with
`target-trc=linear`. The fork layer used `ExtendedLinearITUR_2020`, `rgba16Float`,
`wantsExtendedDynamicRangeContent=true`, and HDR10 metadata with
`opticalOutputScale=100`.

Both the initial attach and the auto-recreated attach logged the complete configuration:

```text
mpv external output HDR=true wantsEDR=true
  colorspace=ExtendedLinearITUR_2020 metadata=hdr10
  screenMaxEDR=1.0000 screenPotentialEDR=10.1524
```

The same cycles also logged `NativeWindow.Bind: bound=true`, `vo=gpu-next`,
`hwdec-current=videotoolbox`, P010/BT.2020/PQ source parameters, resize to `640x552`, and
detach. This closes the W1 diagnostic chain for explicit target selection and repeated
external-layer configuration. It does not close native HDR acceptance: the AppKit screen
reported current max EDR `1.0`, and no independent per-layer `headroom > 1`, visible
high-highlight comparison, or luminance measurement was obtained. `screenPotentialEDR`
`10.1524` only proves that an EDR attempt is possible.

The rebuilt diagnostic artifact SHA-256 was
`600e29e8c47a2c781a818187617fb661999ad019b1b45ff30530201e92a2aefd`. The test app was
stopped, leftover test processes were terminated, and stock libmpv was restored with SHA-256
`5d6e83ee94f35eff70d674e4b86ee4c00ffe36b5656ddbbdb562174f7b2c85d7`.

## macOS Vulkan swapchain format follow-up

Post-present instrumentation showed that the prior layer configuration was not enough:
MoltenVK had selected `bgr10a2Unorm` for the Vulkan swapchain, even though the layer was
configured for EDR. This did not match the known native-surface contract, which uses
`rgba16Float`.

The fork then added a macOS-only libplacebo swapchain hint requiring at least 16 color and
alpha bits. The next run produced after present:

```text
mpv external output post-present
pixelFormat=rgba16Float device=present drawable=3840x2160
HDR=true wantsEDR=true colorspace=ExtendedLinearITUR_2020
metadata=hdr10 screenMaxEDR=1.0000 screenPotentialEDR=10.1524
```

Both the initial and recreated native-window cycles selected `rgba16Float` and completed
bind, gpu-next playback, resize, and detach. This closes the swapchain-format sub-gate and
removes `bgr10a2Unorm` as the current format mismatch. It still does not prove compositor
activation: the screen's current EDR value remained `1.0`, and no independent mpv-layer
headroom or visible high-highlight measurement was obtained.

The final isolated app was restored to stock libmpv and no test process remained. The stock
framework SHA-256 remained
`5d6e83ee94f35eff70d674e4b86ee4c00ffe36b5656ddbbdb562174f7b2c85d7`.

## Same-display NativeSurface control

For attribution, the isolated host was also run with stock libmpv and the existing
`NativeSurface` path on the same display. An explicit test-only HDR configuration used
`transfer=pq`, and the native-surface result was:

```text
active=true
capable=true
pixelFormat=rgba16Float
colorSpace=extended-linear-bt2020
headroom=1.0
potentialHeadroom=10.1524
```

This confirms the current display mode passes the project's EDR attempt gate. It does not
prove actual HDR luminance: the current headroom remained `1.0`, and the project's own
NativeSurface implementation treats potential headroom as a pre-activation condition rather
than visible-output proof. The mpv fork now matches the same format/colorspace/metadata
configuration, but still lacks an equivalent independent mpv-layer active/highlight proof.

## Dolby Vision input inventory

The local media inventory was checked with `ffprobe`. The available diagnostic inputs are:

```text
luna-pq-six-bands.mp4          HEVC Main 10, BT.2020, SMPTE 2084 PQ
luna-pq-highlight-test.mp4     HEVC Main 10, BT.2020, SMPTE 2084 PQ
影视飓风年度样片.mp4             HEVC Main 10, BT.2020, ARIB STD-B67 HLG
luna-sdr-720p-bt709-control.mp4 H.264 High, BT.709 SDR
```

No local stream exposed confirmed Dolby Vision profile/RPU/BL/EL metadata. The HLG sample
must remain an HDR/HLG control, not a Dolby Vision input. A future DV run requires a known
profile-labelled sample and must record the stream side-data/profile before drawing any DV
conclusion.

## macOS 26 compositor request candidate

The host is macOS 26.6.2, whose QuartzCore SDK provides `CALayer.preferredDynamicRange`
and `contentsHeadroom`. The fork was tested with the new API in addition to the legacy EDR
properties:

```text
dynamicRange=CADynamicRange(_rawValue: high)
contentsHeadroom=10.0000
pixelFormat=rgba16Float
colorspace=ExtendedLinearITUR_2020
metadata=hdr10
wantsEDR=true
```

The result repeated for both initial and recreated attach. This closes the last identified
configuration candidate for the current macOS SDK. However, the same post-present log still
reported `screenMaxEDR=1.0000` and `screenPotentialEDR=10.1524`; no public API exposed a
per-layer compositor headroom value, and no luminance/highlight proof was obtained. The new
API therefore proves that the layer requested high dynamic range, not that WindowServer
displayed above SDR reference white.

## 2026-09-06 ScreenCaptureKit cross-check

The deprecated `CGDisplayStream` probe was not usable on this macOS 26 host: runtime
creation returned `CGDisplayStreamCreateWithDispatchQueue failed`. A separate
ScreenCaptureKit probe successfully started `captureDynamicRange=HDRLocalDisplay` with
`pixelFormat=64RGBAHalf`, receiving five real display frames with pixel format
`0x52476841` (`RGhA`) and `IOSurfaceContentHeadroom=1`.

This is independent screen-frame evidence, but not a player HDR-pass result: the probe
requests an HDR-capable capture format, while the sampled surface reported headroom `1`.
That value is a capture-surface annotation, not a per-layer luminance measurement or proof
that the compositor reduced the video to SDR. It therefore preserves the distinction
between capture-format capability and compositor-visible luminance.

An attempted concurrent run served the known PQ clip over localhost to avoid macOS file
access denial for `Downloads`. The player reached `p010`, `bt2020-ncl`, `pq`, and
`sigPeak=49.261`, but that Flutter launch logged `vo=gpu-next: Failed initializing any
suitable GPU context` before a presentable frame. Its ScreenCaptureKit frames still
reported `IOSurfaceContentHeadroom=1`; this run is not accepted as an HDR-output verdict.
It remains a startup-context blocker requiring a reproducible launch comparison.
