import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var clipboardChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "llamadart_chat/clipboard",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "readMedia" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      guard let self else {
        result(
          FlutterError(
            code: "clipboard_unavailable",
            message: "Clipboard access is no longer available.",
            details: nil
          )
        )
        return
      }
      self.readClipboardMedia(
        allowImage: arguments?["allowImage"] as? Bool ?? false,
        allowAudio: arguments?["allowAudio"] as? Bool ?? false,
        result: result
      )
    }
    clipboardChannel = channel
  }

  private func readClipboardMedia(
    allowImage: Bool,
    allowAudio: Bool,
    result: @escaping FlutterResult
  ) {
    let pasteboard = UIPasteboard.general
    if allowImage, let data = pasteboard.image?.pngData() {
      completeClipboardRead(data: data, kind: "image", result: result)
      return
    }
    guard allowAudio else {
      result(nil)
      return
    }

    for provider in pasteboard.itemProviders {
      guard let type = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .audio) == true
      }) else {
        continue
      }
      provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
        DispatchQueue.main.async {
          guard let self else {
            result(
              FlutterError(
                code: "clipboard_unavailable",
                message: "Clipboard access is no longer available.",
                details: nil
              )
            )
            return
          }
          guard error == nil, let data else {
            result(
              FlutterError(
                code: "clipboard_read_failed",
                message: "Could not read the clipboard attachment.",
                details: error?.localizedDescription
              )
            )
            return
          }
          self.completeClipboardRead(data: data, kind: "audio", result: result)
        }
      }
      return
    }
    result(nil)
  }

  private func completeClipboardRead(
    data: Data,
    kind: String,
    result: @escaping FlutterResult
  ) {
    guard data.count <= 64 * 1024 * 1024 else {
      result(
        FlutterError(
          code: "attachment_too_large",
          message: "Clipboard attachment is larger than 64 MB.",
          details: nil
        )
      )
      return
    }
    result([
      "kind": kind,
      "bytes": FlutterStandardTypedData(bytes: data),
    ])
  }
}
