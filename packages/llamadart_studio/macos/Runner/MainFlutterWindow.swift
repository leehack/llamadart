import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 420, height: 600)

    if let visible = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
      let width = min(1360.0, visible.width * 0.92)
      let height = min(880.0, visible.height * 0.90)
      let originX = visible.origin.x + (visible.width - width) / 2.0
      let originY = visible.origin.y + (visible.height - height) / 2.0
      self.setFrame(
        NSRect(x: originX, y: originY, width: width, height: height),
        display: true
      )
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.title = "llamadart Studio"
    NSApp.mainMenu?.items.first?.title = "llamadart Studio"
  }
}
