import AuthenticationServices
import Flutter
import Foundation
import UIKit

/// What the SSO redirect to `kemlock://sso` has to be to count: this sign-in's own, with its `state`. The
/// session delivers only to the one that started it, but the redirect is checked anyway, as Android's is. The
/// code it carries is useless without Dart's PKCE verifier and the device key either way.
enum SsoCallback {
  static let scheme = "kemlock"
  static let host = "sso"

  /// A state of 16 to 256 URL-safe characters, as the server takes it.
  static func isValidState(_ state: String) -> Bool {
    guard (16...256).contains(state.count) else { return false }
    return state.unicodeScalars.allSatisfy { scalar in
      scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
    }
  }

  /// [url] when it is a redirect to `kemlock://sso` carrying [state], else nil.
  static func accept(_ url: URL, state: String) -> URL? {
    guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let got = items.first(where: { $0.name == "state" })?.value
    else { return nil }
    // Compared without stopping at the first difference
    let a = Array(got.utf8)
    let b = Array(state.utf8)
    guard a.count == b.count else { return nil }
    var difference: UInt8 = 0
    for index in 0..<a.count { difference |= a[index] ^ b[index] }
    return difference == 0 ? url : nil
  }
}

/// The phone's side of `lib/platform/browser_auth.dart`, `com.kemlock.app/browser_auth`: an
/// `ASWebAuthenticationSession` with callback scheme `kemlock`, the system's own sheet. The app draws no view of
/// its own and never sees the provider's page; the redirect is delivered to this session only.
final class BrowserAuthChannel: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = BrowserAuthChannel()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/browser_auth", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in shared.handle(call, result: result) }
  }

  private var session: ASWebAuthenticationSession?
  private var pending: FlutterResult?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "authenticate":
      let arguments = call.arguments as? [String: Any] ?? [:]
      guard let text = arguments["url"] as? String, let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false,
        let state = arguments["state"] as? String, SsoCallback.isValidState(state)
      else {
        return result(FlutterError(code: "failed", message: "A sign-in needs an https address and a state.", details: nil))
      }
      start(url, state: state, result: result)
    case "cancel":
      finish(FlutterError(code: "cancelled", message: nil, details: nil))
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(_ url: URL, state: String, result: @escaping FlutterResult) {
    // A second sign-in replaces the first, which ends as a cancel
    finish(FlutterError(code: "cancelled", message: nil, details: nil))
    pending = result
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SsoCallback.scheme) { [weak self] callback, error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          return self.finish(FlutterError(code: "cancelled", message: nil, details: nil))
        }
        if let error = error {
          return self.finish(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
        }
        guard let callback = callback, let accepted = SsoCallback.accept(callback, state: state) else {
          return self.finish(FlutterError(code: "failed", message: "The redirect wasn't this sign-in's.", details: nil))
        }
        self.finish(accepted.absoluteString)
      }
    }
    session.presentationContextProvider = self
    self.session = session
    if !session.start() {
      finish(FlutterError(code: "failed", message: "The browser sheet couldn't open.", details: nil))
    }
  }

  private func finish(_ value: Any?) {
    let result = pending
    pending = nil
    let open = session
    session = nil
    open?.cancel()
    result?(value)
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
  }
}
