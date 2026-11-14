import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var inferenceActivityToken: NSObjectProtocol?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    inferenceActivityToken = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "llamadart Studio local AI inference and model downloads"
    )
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if let token = inferenceActivityToken {
      ProcessInfo.processInfo.endActivity(token)
      inferenceActivityToken = nullToken()
    }
    super.applicationWillTerminate(notification)
  }

  private func nullToken() -> NSObjectProtocol? {
    return nil
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
