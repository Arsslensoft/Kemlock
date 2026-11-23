import Flutter
import Foundation
import UIKit
import UserNotifications

/// What a push message may ask for, and the token's text. A message carries only its type, `sync` or `approval`,
/// as `PushNudge` in kemlock_ports reads it; anything else it carries is not read.
enum PushPayload {
  static let types: Set<String> = ["sync", "approval"]

  /// The nudge type of a remote notification's `userInfo`, or nil when it names none this build knows.
  static func nudgeType(_ userInfo: [AnyHashable: Any]) -> String? {
    guard let type = userInfo["type"] as? String, types.contains(type) else { return nil }
    return type
  }

  /// The token as lower-case hex, which is how the relay takes an APNs token.
  static func hex(_ token: Data) -> String {
    token.map { String(format: "%02x", $0) }.joined()
  }
}

/// The phone's side of `lib/platform/push.dart`, `com.kemlock.app/push`: this phone's APNs token, and the nudges
/// that arrive with it (add-kemlock-server-sync, design 13). `token` asks for permission to show alerts, then
/// registers with APNs and answers with the token; a refusal, or a failed registration, answers nil. The app
/// delegate hands over the token and each remote notification; `nudge` goes to Dart with the type and nothing
/// else.
final class PushChannel {
  static let shared = PushChannel()

  static func register(with registrar: FlutterPluginRegistrar) {
    shared.attach(FlutterMethodChannel(name: "com.kemlock.app/push", binaryMessenger: registrar.messenger()))
  }

  private var channel: FlutterMethodChannel?
  private var token: String?
  private var waiting: [FlutterResult] = []

  private func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "token": self.requestToken(result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func requestToken(_ result: @escaping FlutterResult) {
    if let token = token { return result(token) }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
      DispatchQueue.main.async {
        guard granted else { return result(nil) }
        self.waiting.append(result)
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  /// APNs gave this phone [data] as its token.
  func registered(_ data: Data) {
    let text = PushPayload.hex(data)
    token = text
    let answers = waiting
    waiting = []
    for answer in answers { answer(text) }
  }

  /// APNs refused to register this phone: whoever waits for a token gets none.
  func registrationFailed() {
    let answers = waiting
    waiting = []
    for answer in answers { answer(nil) }
  }

  /// A remote notification arrived. It reaches Dart with its type only, and only a type this build knows.
  func received(_ userInfo: [AnyHashable: Any]) {
    guard let type = PushPayload.nudgeType(userInfo) else { return }
    channel?.invokeMethod("nudge", arguments: ["type": type])
  }
}
