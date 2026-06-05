#if os(iOS)
import Flutter
import UIKit
import llama
import CLiteRTLM
#elseif os(macOS)
import FlutterMacOS
import Cocoa
import llama
import CLiteRTLM
#endif

public class LlamadartAppleSpmPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}

@_cdecl("llama_dart_set_log_level")
public func llama_dart_set_log_level(_ level: Int32) {}
