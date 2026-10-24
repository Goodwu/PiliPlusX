import Cocoa
import FlutterMacOS
import media_kit_video

@main
class AppDelegate: FlutterAppDelegate {
  // Keep engines discoverable when their window is hidden or closed. The
  // engine owns its lifetime; this registry does not extend it.
  private let mediaKitEngines = NSHashTable<FlutterEngine>.weakObjects()

  func registerMediaKitEngine(_ engine: FlutterEngine) {
    mediaKitEngines.add(engine)
    MediaKitVideoPlugin.recordWakeupShutdownDiagnostic("host.engine.registered", fields: [
      "engineCount": mediaKitEngines.allObjects.count,
    ])
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let reply = super.applicationShouldTerminate(sender)
    MediaKitVideoPlugin.recordWakeupShutdownDiagnostic("host.applicationShouldTerminate", fields: [
      "reply": Int(reply.rawValue), "engineCount": mediaKitEngines.allObjects.count,
    ])
    if reply == .terminateNow {
      for engine in mediaKitEngines.allObjects {
        MediaKitVideoPlugin.prepareForEngineShutdown(engine)
      }
    }
    // Cancellation and deferred termination leave callbacks operational.
    return reply
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in NSApp.windows {
        if !window.isVisible {
          window.setIsVisible(true)
        }
        window.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    return true
  }
}
