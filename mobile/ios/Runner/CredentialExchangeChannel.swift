import AuthenticationServices
import Flutter
import UIKit

/// What Apple's Credential Exchange types become in CXF JSON, and back (openspec: plan
/// add-credential-exchange, decision 1). Apple's `ASImportable*` types are Codable and are
/// documented as CXF's own entities, with dates in seconds since 1970, so the app gives Dart the
/// JSON a CXF file would hold and `lib/features/import/formats/cxf.dart` reads it as it reads a
/// file. Nothing here maps to Kemlock's kinds.
///
/// The header is written here, from the properties `ASExportedCredentialData` documents, and not
/// by that type's own coding: the names Dart reads (`version`, `exporterRpId`) are the
/// specification's, and Apple's page says only that the accounts, items and credentials are CXF's.
/// Byte strings are encoded as base64url without padding, which is how CXF writes them, if Apple's
/// types leave the encoding to the encoder.
@available(iOS 26.0, *)
enum CredentialExchangeJSON {
  /// The header of a CXF 1.0 payload, with the specification's member names.
  private struct Header: Codable {
    struct Version: Codable {
      let major: Int
      let minor: Int
    }

    let version: Version
    let exporterRpId: String
    let exporterDisplayName: String
    let timestamp: Date
    let accounts: [ASImportableAccount]
  }

  /// The CXF JSON of what another app exported.
  static func encode(_ data: ASExportedCredentialData) throws -> Data {
    let header = Header(
      version: version(of: data.formatVersion),
      exporterRpId: data.exporterRelyingPartyIdentifier,
      exporterDisplayName: data.exporterDisplayName,
      timestamp: data.timestamp,
      accounts: data.accounts)
    return try encoder().encode(header)
  }

  /// What a CXF JSON payload holds, in Apple's types: the other way of [encode], for an export.
  /// [formatVersion] is the one the importing app said it reads (`requestExport`'s options).
  static func decode(
    _ json: Data, formatVersion: ASExportedCredentialData.FormatVersion = .v1
  ) throws -> ASExportedCredentialData {
    let header = try decoder().decode(Header.self, from: json)
    return ASExportedCredentialData(
      accounts: header.accounts,
      formatVersion: formatVersion,
      exporterRelyingPartyIdentifier: header.exporterRpId,
      exporterDisplayName: header.exporterDisplayName,
      timestamp: header.timestamp)
  }

  private static func version(of format: ASExportedCredentialData.FormatVersion) -> Header.Version {
    switch format {
    case .v1: return Header.Version(major: 1, minor: 0)
    @unknown default: return Header.Version(major: 1, minor: 0)
    }
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.dataEncodingStrategy = .custom { data, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(base64url(data))
    }
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    decoder.dataDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      guard let data = bytes(fromBase64url: text) else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not base64url"))
      }
      return data
    }
    return decoder
  }

  /// [data] as base64url, without padding.
  static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// The bytes of [text], base64url with or without padding; nil when it isn't base64url.
  static func bytes(fromBase64url text: String) -> Data? {
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while standard.count % 4 != 0 { standard += "=" }
    return Data(base64Encoded: standard)
  }
}

/// The phone's side of `lib/platform/credential_exchange.dart`, `com.kemlock.app/credential_exchange`
/// (openspec: plan add-credential-exchange, decision 7). Another app's export starts there, on
/// iOS 26 and later: the system launches Kemlock with an `NSUserActivity` whose `userInfo` holds a
/// token. The channel keeps the token, as SetupLinks keeps a link, until Dart asks for it or the
/// app runs and it is sent. It reads nothing yet: Dart asks for the data (`fetch`) only after a
/// vault is open, so the plain payload never waits in memory behind the lock screen, and the JSON
/// comes back over the channel, never through a file. Before iOS 26 it answers `supported` with
/// false and nothing else.
final class CredentialExchangeChannel {
  static let shared = CredentialExchangeChannel()

  private var channel: FlutterMethodChannel?
  private(set) var initial: String?
  private var asked = false

  func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.kemlock.app/credential_exchange", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "supported":
        result(Self.supported)
      case "initial":
        result(self.initial)
        self.initial = nil
        self.asked = true
      case "forget":
        self.initial = nil
        result(nil)
      case "fetch":
        let arguments = call.arguments as? [String: Any]
        guard let text = arguments?["token"] as? String, let token = UUID(uuidString: text) else {
          return result(FlutterError(code: "badToken", message: nil, details: nil))
        }
        self.fetch(token, result: result)
      case "export":
        self.export(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Whether this phone can take part: iOS 26 and later.
  static var supported: Bool {
    if #available(iOS 26, *) { return true }
    return false
  }

  /// An activity the scene was opened with or handed. True when it was a credential exchange, whose
  /// token is kept for Dart to ask for until it has, then sent.
  @discardableResult
  func arrived(_ activity: NSUserActivity) -> Bool {
    guard #available(iOS 26, *) else { return false }
    guard activity.activityType == ASCredentialExchangeActivity,
      let token = activity.userInfo?[ASCredentialImportToken] as? UUID
    else { return false }
    if asked, let channel {
      channel.invokeMethod("token", arguments: token.uuidString)
    } else {
      initial = token.uuidString
    }
    return true
  }

  /// Reads the export behind [token] and answers its CXF JSON as a string. An error carries a code
  /// and where it came from, never a value: `unreadable` when Apple's types can't be written as
  /// JSON, `failed` for the system's refusal (a token that isn't the one the system expected).
  private func fetch(_ token: UUID, result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else {
      return result(FlutterError(code: "unsupported", message: nil, details: nil))
    }
    Task {
      do {
        let data = try await ASCredentialImportManager().importCredentials(token: token)
        let json = try CredentialExchangeJSON.encode(data)
        DispatchQueue.main.async { result(String(decoding: json, as: UTF8.self)) }
      } catch is EncodingError {
        DispatchQueue.main.async { result(FlutterError(code: "unreadable", message: nil, details: nil)) }
      } catch {
        let origin = error as NSError
        DispatchQueue.main.async {
          result(FlutterError(code: "failed", message: "\(origin.domain) \(origin.code)", details: nil))
        }
      }
    }
  }
}

extension CredentialExchangeChannel {
  /// The window the system's sheet of apps is shown over: the foreground scene's key window.
  @available(iOS 26, *)
  private static func presentationAnchor() -> ASPresentationAnchor? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    return scene?.keyWindow ?? scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
  }

  /// Whether [error] is the person closing the system's sheet.
  @available(iOS 26, *)
  private static func isCancel(_ error: Error) -> Bool {
    let origin = error as NSError
    return origin.domain == ASAuthorizationError.errorDomain
      && origin.code == ASAuthorizationError.canceled.rawValue
  }

  /// Hands the payload Dart writes to another app (openspec: plan add-credential-exchange, task 8.3):
  /// `requestExport(for:)` opens the system's sheet, which says what an export risks and lets the
  /// person choose the receiving app, and answers the format version that app reads. Only then is
  /// Dart asked for the payload (`exportJson`, answered by the channel's Dart side), so that no
  /// plaintext waits in memory while the person decides, and none is ever written if they close
  /// the sheet. The payload is decoded into Apple's types at that version, and
  /// `exportCredentials(_:)` gives it to the system, which launches the other app. Nothing is
  /// written to a file, and Apple's page says the system doesn't either. The data is never logged.
  /// An error carries a code and where it came from, never a value: `cancelled` when the person
  /// closed the sheet, `unreadable` when the payload doesn't decode, `failed` otherwise.
  fileprivate func export(result: @escaping FlutterResult) {
    guard #available(iOS 26, *) else {
      return result(FlutterError(code: "unsupported", message: nil, details: nil))
    }
    guard let anchor = Self.presentationAnchor() else {
      return result(FlutterError(code: "failed", message: "noWindow", details: nil))
    }
    guard let channel else {
      return result(FlutterError(code: "failed", message: "noChannel", details: nil))
    }
    Task { @MainActor in
      do {
        let manager = ASCredentialExportManager(presentationAnchor: anchor)
        // nil: Kemlock has the one credential provider extension
        let options = try await manager.requestExport(for: nil)
        // The person has chosen an app and gone on: only now is the payload made
        let json = try await Self.payload(from: channel)
        let data = try CredentialExchangeJSON.decode(Data(json.utf8), formatVersion: options.formatVersion)
        try await manager.exportCredentials(data)
        result(nil)
      } catch is DecodingError {
        result(FlutterError(code: "unreadable", message: nil, details: nil))
      } catch is PayloadError {
        result(FlutterError(code: "failed", message: "payload", details: nil))
      } catch {
        if Self.isCancel(error) {
          result(FlutterError(code: "cancelled", message: nil, details: nil))
        } else {
          let origin = error as NSError
          result(FlutterError(code: "failed", message: "\(origin.domain) \(origin.code)", details: nil))
        }
      }
    }
  }

  /// Dart had no payload to give: it was never asked for one, or it failed to write it.
  private struct PayloadError: Error {}

  /// Asks Dart for the CXF JSON of the export under way, which it answers once.
  @MainActor
  private static func payload(from channel: FlutterMethodChannel) async throws -> String {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      channel.invokeMethod("exportJson", arguments: nil) { reply in
        if let text = reply as? String {
          continuation.resume(returning: text)
        } else {
          // A FlutterError, FlutterMethodNotImplemented or nil: never carried further
          continuation.resume(throwing: PayloadError())
        }
      }
    }
  }
}
