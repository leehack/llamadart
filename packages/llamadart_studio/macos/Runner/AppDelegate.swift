import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var inferenceActivityToken: NSObjectProtocol?

  // Flutter forwards these lifecycle notifications through its registrar and
  // has no superclass implementation of either optional delegate callback.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    inferenceActivityToken = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "llamadart Studio local AI inference and model downloads"
    )
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if let token = inferenceActivityToken {
      inferenceActivityToken = nil
      ProcessInfo.processInfo.endActivity(token)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
