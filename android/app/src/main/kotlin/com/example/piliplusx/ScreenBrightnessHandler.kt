package com.example.piliplusx

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * DV006: native handler for the `github.com/aaassseee/screen_brightness`
 * MethodChannel/EventChannels used by `screen_brightness_platform_interface`.
 *
 * The app depends on the interface package only; without this handler every
 * brightness call throws MissingPluginException, which the player swallows —
 * the on-screen percentage changed while the actual brightness never did
 * (defect reported on multiple Android devices).
 *
 * Semantics kept aligned with the reference Android implementation of the
 * screen_brightness plugin:
 * - system value: Settings.System.SCREEN_BRIGHTNESS normalized to 0..1
 * - application value: Activity window `screenBrightness` attribute
 * - writing the system brightness while auto-brightness is ON first switches
 *   the device to manual mode (otherwise the write has no visible effect)
 * - `resetApplicationScreenBrightness` clears the window override
 */
class ScreenBrightnessHandler(
    private val activity: Activity,
    flutterEngine: FlutterEngine,
) {
    private val messenger = flutterEngine.dartExecutor.binaryMessenger
    private val methodChannel =
        MethodChannel(messenger, "github.com/aaassseee/screen_brightness")
    private val applicationEvents = EventChannel(
        messenger,
        "github.com/aaassseee/screen_brightness/application_brightness_changed",
    )
    private val systemEvents = EventChannel(
        messenger,
        "github.com/aaassseee/screen_brightness/system_brightness_changed",
    )

    private var applicationSink: EventChannel.EventSink? = null
    private var systemSink: EventChannel.EventSink? = null
    private var systemObserver: ContentObserver? = null
    private var lastSystemBrightness = currentSystemBrightness()

    private val resolver: ContentResolver get() = activity.contentResolver

    private val systemObserverImpl = object : ContentObserver(null) {
        override fun onChange(selfChange: Boolean) {
            val value = currentSystemBrightness()
            if (value != lastSystemBrightness) {
                lastSystemBrightness = value
                systemSink?.success(value)
            }
        }
    }

    fun start() {
        methodChannel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getSystemScreenBrightness" ->
                        result.success(currentSystemBrightness())
                    "setSystemScreenBrightness" -> {
                        val brightness = call.argument<Number>("brightness")
                        if (brightness == null) {
                            result.error("-9", "value returns null", null)
                        } else {
                            setSystemBrightness(brightness.toDouble())
                            result.success(null)
                        }
                    }
                    "getApplicationScreenBrightness" ->
                        result.success(currentApplicationBrightness())
                    "setApplicationScreenBrightness" -> {
                        val brightness = call.argument<Number>("brightness")
                        if (brightness == null) {
                            result.error("-9", "value returns null", null)
                        } else {
                            setApplicationBrightness(brightness.toDouble())
                            result.success(null)
                        }
                    }
                    "resetApplicationScreenBrightness" -> {
                        setApplicationBrightness(Double.NaN)
                        result.success(null)
                    }
                    "hasApplicationScreenBrightnessChanged" ->
                        result.success(
                            activity.window.attributes.screenBrightness >= 0f,
                        )
                    "isAutoReset" -> result.success(false)
                    "setAutoReset" -> result.success(null)
                    "isAnimate" -> result.success(false)
                    "setAnimate" -> result.success(null)
                    "canChangeSystemBrightness" -> result.success(true)
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                result.error("-1", "brightness handler failure", null)
            }
        }

        applicationEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                applicationSink = sink
            }

            override fun onCancel(args: Any?) {
                applicationSink = null
            }
        })

        systemEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                systemSink = sink
                val uri = Settings.System.getUriFor(
                    Settings.System.SCREEN_BRIGHTNESS,
                )
                systemObserver = systemObserverImpl
                resolver.registerContentObserver(uri, false, systemObserver!!)
            }

            override fun onCancel(args: Any?) {
                systemObserver?.let { resolver.unregisterContentObserver(it) }
                systemObserver = null
                systemSink = null
            }
        })
    }

    private fun applicationEventsHandler() = object : EventChannel.StreamHandler {
        override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
            applicationSink = sink
        }

        override fun onCancel(args: Any?) {
            applicationSink = null
        }
    }

    private fun currentSystemBrightness(): Double {
        val raw: Double = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            Settings.System.getFloat(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS,
                0f,
            ).toDouble() / 255f
        } else {
            @Suppress("DEPRECATION")
            Settings.System.getInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS,
                0,
            ) / 255.0
        }
        return raw.coerceIn(0.0, 1.0)
    }

    private fun setSystemBrightness(value: Double) {
        // Auto mode silently ignores manual writes; switching to manual first
        // makes the gesture visible, which is what the user expects.
        if (Settings.System.getInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC,
            ) == Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC
        ) {
            Settings.System.putInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
            )
        }
        @Suppress("DEPRECATION")
        Settings.System.putInt(
            resolver,
            Settings.System.SCREEN_BRIGHTNESS,
            (value.coerceIn(0.0, 1.0) * 255).toInt(),
        )
    }

    private fun currentApplicationBrightness(): Double {
        val attr = activity.window.attributes.screenBrightness
        return (if (attr < 0f) currentSystemBrightness() else attr.toDouble())
            .coerceIn(0.0, 1.0)
    }

    private fun setApplicationBrightness(value: Double) {
        val attributes = activity.window.attributes
        attributes.screenBrightness = value.coerceIn(0.0, 1.0).toFloat()
        activity.window.attributes = attributes
        lastSystemBrightness = currentSystemBrightness()
    }

    fun stop() {
        systemObserver?.let { resolver.unregisterContentObserver(it) }
        systemObserver = null
        systemSink = null
        applicationSink = null
    }
}
