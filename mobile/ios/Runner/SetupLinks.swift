import Flutter
import UIKit

/// Hands `otpauth://` and `otpauth-migration://` links to lib/platform/setup_links.dart: the one
/// the app was opened with, asked for once, and those that arrive while it runs. Handling the
/// scheme lists the app under Settings › General › AutoFill & Passwords › Set Up Codes In.
/// Flutter's own deep linking is off in Info.plist, since it would hand the router the link.
final class SetupLinks {
  static let shared = SetupLinks()

  private var channel: FlutterMethodChannel?
  private var initial: String?
  private var asked = false

  func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/links", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "initial", let self else { return result(FlutterMethodNotImplemented) }
      result(self.initial)
      self.initial = nil
      self.asked = true
    }
    self.channel = channel
  }

  /// A link the scene was opened with or handed: kept for Dart to ask for until it has, then sent.
  func arrived(_ url: URL) {
    let link = url.absoluteString
    let scheme = url.scheme?.lowercased()
    guard scheme == "otpauth" || scheme == "otpauth-migration" else { return }
    if asked, let channel {
      channel.invokeMethod("link", arguments: link)
    } else {
      initial = link
    }
  }
}
