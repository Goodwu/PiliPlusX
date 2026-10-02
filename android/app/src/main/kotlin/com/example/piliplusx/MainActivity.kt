package com.example.piliplusx

import android.content.Intent
import android.content.res.Configuration
import android.content.pm.ActivityInfo
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
                if (call.method == "setWindowHdrMode") {
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

    // 设备 HDR 能力探测（原 probeHdrCapabilities）已删除：Android 的能力
    // 查询与路由全部由 media-kit 的 HdrCapabilities.query / HdrVideoSession
    // 承担（R1/R2），App 侧不保留设备特定探测代码。

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
