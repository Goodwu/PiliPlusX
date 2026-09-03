package com.example.piliplusx

import android.content.Intent
import android.content.res.Configuration
import android.content.pm.ActivityInfo
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val hdrChannel = "piliplusx/hdr_capabilities"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hdrChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "probe") {
                    val arguments = call.arguments as? Map<*, *>
                    result.success(
                        probeHdrCapabilities(arguments?.get("codec") as? String),
                    )
                } else if (call.method == "setWindowHdrMode") {
                    val arguments = call.arguments as? Map<*, *>
                    result.success(
                        setWindowHdrMode(arguments?.get("hdr") as? Boolean ?: false),
                    )
                } else if (call.method == "configureOutput") {
                    val arguments = call.arguments as? Map<*, *>
                    val surfaceId = arguments?.get("surfaceId") as? String
                    val configured = !surfaceId.isNullOrBlank() && setWindowHdrMode(true)
                    result.success(mapOf(
                        "backend" to "android-surface-dataspace",
                        "appliedColorSpace" to if (configured) {
                            arguments?.get("transfer") as? String ?: "unknown"
                        } else "sdr",
                        "active" to configured,
                        "sourceProcessing" to if (configured) "native" else "tone-map",
                        "outputEncoding" to if (configured) "pq-or-hlg" else "sdr",
                        "dynamicMetadataApplied" to false,
                        "supportedInputFormats" to listOf("hdr10", "hlg"),
                        "supportedOutputFormats" to if (configured) listOf("pq", "hlg") else listOf("sdr"),
                        "failureReason" to if (configured) "" else
                            "surface-dataspace-not-acknowledged",
                    ))
                } else if (call.method == "resetOutput") {
                    result.success(setWindowHdrMode(false))
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun setWindowHdrMode(hdr: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            window.setColorMode(
                if (hdr) ActivityInfo.COLOR_MODE_HDR
                else ActivityInfo.COLOR_MODE_DEFAULT,
            )
            window.colorMode == if (hdr) {
                ActivityInfo.COLOR_MODE_HDR
            } else {
                ActivityInfo.COLOR_MODE_DEFAULT
            }
        } catch (_: Throwable) {
            false
        }
    }

    private fun probeHdrCapabilities(codec: String?): Map<String, Any> {
        val display = windowManager.defaultDisplay
        val hdrTypes: List<Int> = if (Build.VERSION.SDK_INT >= 24) {
            display?.hdrCapabilities?.supportedHdrTypes?.toList() ?: emptyList()
        } else {
            emptyList()
        }
        fun hdrTypeName(type: Int): String = when (type) {
            1 -> "dolby-vision"
            2 -> "hdr10"
            3 -> "hlg"
            4 -> "hdr10-plus"
            else -> "unknown:$type"
        }
        val decoderProfiles = mutableListOf<String>()
        var decoderHdr = false
        val requestedCodec = codec?.lowercase().orEmpty()
        fun codecMatches(mime: String): Boolean {
            if (requestedCodec.isEmpty()) return true
            return when {
                requestedCodec.contains("hevc") ||
                    requestedCodec.contains("h265") ||
                    requestedCodec.contains("hvc1") -> mime == "video/hevc"
                requestedCodec.contains("vp9") ||
                    requestedCodec.contains("vp09") -> mime == "video/x-vnd.on2.vp9"
                requestedCodec.contains("av1") ||
                    requestedCodec.contains("av01") -> mime == "video/av01"
                else -> false
            }
        }
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .filterNot { it.isEncoder }
                .forEach { info ->
                    info.supportedTypes
                        .filter {
                            it.equals("video/hevc", true) ||
                                it.equals("video/x-vnd.on2.vp9", true) ||
                                it.equals("video/av01", true)
                        }
                        .filter(::codecMatches)
                        .forEach { type ->
                            info.getCapabilitiesForType(type).profileLevels
                                .forEach { profileLevel ->
                                    if (profileLevel.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 ||
                                        profileLevel.profile == MediaCodecInfo.CodecProfileLevel.VP9Profile2 ||
                                        (Build.VERSION.SDK_INT >= 29 &&
                                            profileLevel.profile == MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10 &&
                                            type.equals("video/av01", true))
                                    ) {
                                        decoderHdr = true
                                        decoderProfiles += "$type:profile=${profileLevel.profile}"
                                    }
                                }
                        }
                }
        } catch (_: Throwable) {
            decoderProfiles += "probe-error"
        }
        val vulkan = Build.VERSION.SDK_INT >= 24 &&
            packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL,
                1,
            )
        val displayHdr = hdrTypes.isNotEmpty()
        val platformView = Build.VERSION.SDK_INT >= 23
        val hcpp = Build.VERSION.SDK_INT >= 34 && vulkan && platformView && displayHdr
        return mapOf(
            "platform" to "android",
            "nativeBackend" to if (hcpp) "platform-view-dataspace" else "none",
            "androidApi" to Build.VERSION.SDK_INT,
            "displayHdr" to displayHdr,
            "decoderHdr" to decoderHdr,
            // Surface/PlatformView capability is not proof that the native
            // HDR color space has been established. Keep this false until
            // the HDR surface path explicitly sets and verifies it.
            "nativeOutput" to false,
            "nativeOutputCapable" to hcpp,
            "nativeOutputActive" to false,
            "vulkan" to vulkan,
            "platformView" to platformView,
            "hcpp" to hcpp,
            "displayFormats" to hdrTypes.map(::hdrTypeName),
            "decoderProfiles" to decoderProfiles,
            "requestedCodec" to requestedCodec,
            "unsupportedReason" to if (hcpp) "" else "android-hdr-capability-incomplete",
        )
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
