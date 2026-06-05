#if os(iOS)
import Flutter
import UIKit
import llama
import LiteRtLm
import CLiteRTLM
#elseif os(macOS)
import FlutterMacOS
import Cocoa
import llama
import LiteRtLm
#endif

public class LlamadartPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
