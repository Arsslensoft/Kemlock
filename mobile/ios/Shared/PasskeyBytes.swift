import CryptoKit
import Foundation

/// The bytes a passkey provider hands a site (WebAuthn Level 3, CTAP 2.1),
/// built as lib/features/passkeys/passkey_bytes.dart builds them and pinned
/// by the fixtures in mobile/test/fixtures/passkeys:
///
/// - registration: authenticator data with the flags user present, user
///   verified, backup eligible, backup state and attested credential data
///   (0x5D), a signature counter of 0, Kemlock's AAGUID, the credential id
///   and the ES256 public key as a COSE key; and the attestation object
///   `{"fmt": "none", "attStmt": {}, "authData": …}` in canonical CBOR;
/// - assertion: authenticator data with user present, user verified, backup
///   eligible and backup state (0x1D) and a counter of 0, signed with ES256
///   after the client data's SHA-256.
enum PasskeyBytes {
  /// Kemlock's AAGUID, which says which provider made a passkey.
  static let aaguid = UUID(uuidString: "f85899be-d2db-4b3b-9b10-9b48e146dc1c")!

  /// The COSE identifier of ES256, the only algorithm Kemlock makes passkeys with.
  static let es256 = -7

  /// UP, UV, BE, BS and AT.
  static let registrationFlags: UInt8 = 0x01 | 0x04 | 0x08 | 0x10 | 0x40

  /// UP, UV, BE and BS.
  static let assertionFlags: UInt8 = 0x01 | 0x04 | 0x08 | 0x10

  /// The length of a new credential id: 16 bytes, which Bitwarden keeps as a GUID.
  static let credentialIdLength = 16

  static var aaguidBytes: Data { withUnsafeBytes(of: aaguid.uuid) { Data($0) } }

  /// SHA-256 of the relying party's id, as authenticator data begins.
  static func rpIdHash(_ rpId: String) -> Data { Data(SHA256.hash(data: Data(rpId.utf8))) }

  /// The ES256 public key at [point] (X9.63, 65 bytes) as a COSE key:
  /// `{1: 2, 3: -7, -1: 1, -2: x, -3: y}`, in canonical order.
  static func coseKey(point: Data) -> Data {
    let bytes = [UInt8](point)
    precondition(bytes.count == 65 && bytes[0] == 4, "not an uncompressed P-256 point")
    return CBOR.map([
      (CBOR.integer(1), CBOR.integer(2)),
      (CBOR.integer(3), CBOR.integer(es256)),
      (CBOR.integer(-1), CBOR.integer(1)),
      (CBOR.integer(-2), CBOR.bytes(Data(bytes[1..<33]))),
      (CBOR.integer(-3), CBOR.bytes(Data(bytes[33..<65]))),
    ])
  }

  /// A registration's authenticator data for a new passkey.
  static func registrationAuthData(rpId: String, credentialId: Data, point: Data) -> Data {
    var out = rpIdHash(rpId)
    out.append(registrationFlags)
    out.append(contentsOf: [0, 0, 0, 0])
    out.append(aaguidBytes)
    out.append(contentsOf: [UInt8(credentialId.count >> 8 & 0xff), UInt8(credentialId.count & 0xff)])
    out.append(credentialId)
    out.append(coseKey(point: point))
    return out
  }

  /// The attestation object of a registration, attestation `none`.
  static func attestationObject(authData: Data) -> Data {
    CBOR.map([
      (CBOR.text("fmt"), CBOR.text("none")),
      (CBOR.text("attStmt"), CBOR.map([])),
      (CBOR.text("authData"), CBOR.bytes(authData)),
    ])
  }

  /// An assertion's authenticator data.
  static func assertionAuthData(rpId: String) -> Data {
    var out = rpIdHash(rpId)
    out.append(assertionFlags)
    out.append(contentsOf: [0, 0, 0, 0])
    return out
  }

  /// What an assertion signs: its authenticator data, then the client data's hash.
  static func assertionSignedBytes(authData: Data, clientDataHash: Data) -> Data { authData + clientDataHash }

  /// An ES256 signature of [message] by [key], DER encoded as WebAuthn wants
  /// it. CryptoKit hashes with SHA-256 and signs with fresh randomness.
  static func sign(_ message: Data, with key: P256.Signing.PrivateKey) throws -> Data {
    try key.signature(for: message).derRepresentation
  }

  /// Whether [signature], DER, is an ES256 signature of [message] by the key at [point].
  static func verify(_ signature: Data, of message: Data, point: Data) -> Bool {
    guard let key = try? P256.Signing.PublicKey(x963Representation: point),
      let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature)
    else { return false }
    return key.isValidSignature(parsed, for: message)
  }

  /// [count] bytes from the system's secure random source.
  static func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess, "no random bytes")
    return Data(bytes)
  }
}

/// The little CBOR passkeys need: integers, byte and text strings, and
/// maps, each in its shortest form. A map's entries are written in the
/// order given, which callers keep canonical.
enum CBOR {
  static func head(_ major: UInt8, _ value: UInt64) -> Data {
    let type = major << 5
    switch value {
    case ..<24: return Data([type | UInt8(value)])
    case ..<0x100: return Data([type | 24, UInt8(value)])
    case ..<0x10000: return Data([type | 25, UInt8(value >> 8), UInt8(value & 0xff)])
    case ..<0x1_0000_0000: return Data([type | 26] + (0..<4).reversed().map { UInt8(value >> (8 * UInt64($0)) & 0xff) })
    default: return Data([type | 27] + (0..<8).reversed().map { UInt8(value >> (8 * UInt64($0)) & 0xff) })
    }
  }

  static func integer(_ value: Int) -> Data {
    value >= 0 ? head(0, UInt64(value)) : head(1, UInt64(-1 - value))
  }

  static func bytes(_ value: Data) -> Data { head(2, UInt64(value.count)) + value }

  static func text(_ value: String) -> Data {
    let encoded = Data(value.utf8)
    return head(3, UInt64(encoded.count)) + encoded
  }

  static func map(_ entries: [(Data, Data)]) -> Data {
    entries.reduce(head(5, UInt64(entries.count))) { $0 + $1.0 + $1.1 }
  }
}

extension Data {
  /// base64url without padding, as WebAuthn and the copy write credential ids and user handles.
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Reads base64url, with or without padding; nil for anything else.
  init?(base64URL text: String) {
    guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }) else { return nil }
    var base64 = text.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if base64.count % 4 == 1 { return nil }
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }
}
