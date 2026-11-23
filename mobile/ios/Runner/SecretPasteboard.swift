import Flutter
import UIKit
import UniformTypeIdentifiers

/// What SecretPasteboard writes to: the general pasteboard, or one that records in the tests.
protocol Pasteboard: AnyObject {
  var changeCount: Int { get }
  func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: Pasteboard {}

/// The phone's side of `com.kemlock.app/clipboard` (lib/platform/secret_clipboard.dart): codes
/// and secrets go on the pasteboard local only, so Universal Clipboard never hands them to the
/// person's Mac or iPad, with an expiry at the delay chosen in Settings, so iOS clears them even
/// when Kemlock was killed first. The token of a copy is the pasteboard's `changeCount` after it,
/// which reading doesn't count as a paste, so no paste prompt shows; `clearIfOurs` empties the
/// pasteboard only while that count hasn't moved, and leaves what was copied since.
final class SecretPasteboard {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/clipboard", binaryMessenger: registrar.messenger())
    let handler = SecretPasteboard()
    channel.setMethodCallHandler { call, result in handler.handle(call, result: result) }
  }

  private let pasteboard: Pasteboard
  private let now: () -> Date

  init(pasteboard: Pasteboard = UIPasteboard.general, now: @escaping () -> Date = Date.init) {
    self.pasteboard = pasteboard
    self.now = now
  }

  /// Puts [text] on the pasteboard, local only, expiring after [seconds] or never when nil.
  /// Returns the token naming this copy.
  func copy(_ text: String, seconds: Int?) -> Int {
    var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
    if let seconds { options[.expirationDate] = now().addingTimeInterval(TimeInterval(seconds)) }
    pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: options)
    return pasteboard.changeCount
  }

  /// Empties the pasteboard unless something was copied after the copy [token] names; true when it did.
  @discardableResult
  func clearIfOurs(_ token: Int) -> Bool {
    guard pasteboard.changeCount == token else { return false }
    pasteboard.setItems([], options: [:])
    return true
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "copy":
      guard let text = arguments["text"] as? String else {
        return result(FlutterError(code: "failed", message: "Nothing to copy", details: nil))
      }
      result(String(copy(text, seconds: (arguments["seconds"] as? NSNumber)?.intValue)))
    case "clearIfOurs":
      // A token this side didn't give names no copy of ours: nothing to clear
      if let token = (arguments["token"] as? String).flatMap(Int.init) { clearIfOurs(token) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
