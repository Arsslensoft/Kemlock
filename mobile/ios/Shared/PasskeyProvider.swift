import CryptoKit
import Foundation

/// What the AutoFill extension decides and makes for a passkey request,
/// apart from its screens, so the tests reach it.
enum PasskeyProvider {
  /// Why a registration is refused.
  enum Refusal: Equatable {
    /// The site takes no ES256 key, the only kind Kemlock makes.
    case algorithm
    /// The site lists a passkey Kemlock already holds for it.
    case excluded
  }

  /// Why a registration for [rpId] is refused, or nil to go ahead: no
  /// ES256 among [algorithms], or one of the [excluded] credentials among
  /// the passkeys Kemlock [held] for that site. An empty list of algorithms
  /// is WebAuthn's default, which takes ES256.
  static func refusal(algorithms: [Int], excluded: [Data], rpId: String, held: [VaultPasskey]) -> Refusal? {
    if !algorithms.isEmpty, !algorithms.contains(PasskeyBytes.es256) { return .algorithm }
    let site = HostMatch.normalize(rpId)
    let mine = Set(held.filter { HostMatch.normalize($0.passkey.rpId) == site }.map(\.passkey.credentialId))
    return excluded.contains(where: mine.contains) ? .excluded : nil
  }

  /// A new passkey and what the site gets back for it.
  struct Registration {
    /// What the inbox and the extension's own record keep.
    let record: PasskeyRecord
    let credentialId: Data
    let attestationObject: Data
  }

  /// A new ES256 passkey for [userName] on [rpId], with a fresh [key] and
  /// 16-byte [credentialId] unless given.
  static func register(
    rpId: String, userName: String, userHandle: Data, key: P256.Signing.PrivateKey = .init(),
    credentialId: Data = PasskeyBytes.randomBytes(PasskeyBytes.credentialIdLength), at date: Date = Date()
  ) -> Registration {
    let authData = PasskeyBytes.registrationAuthData(rpId: rpId, credentialId: credentialId, point: key.publicKey.x963Representation)
    let record = PasskeyRecord(
      credentialId: credentialId.base64URL, rpId: rpId, userHandle: userHandle.base64URL, userName: userName,
      privateKey: key.derRepresentation.base64EncodedString(), createdAt: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    return Registration(record: record, credentialId: credentialId, attestationObject: PasskeyBytes.attestationObject(authData: authData))
  }

  /// The passkeys offered to [rpId]: its own, matched exactly, never a parent
  /// domain's or a subdomain's, and only those [allowed] lists when it lists some.
  static func passkeys(_ all: [VaultPasskey], for rpId: String, allowed: [Data] = []) -> [VaultPasskey] {
    let site = HostMatch.normalize(rpId)
    guard !site.isEmpty else { return [] }
    return all.filter { HostMatch.normalize($0.passkey.rpId) == site && (allowed.isEmpty || allowed.contains($0.passkey.credentialId)) }
  }

  /// The passkey [chosen] names among [opened], with its key: the same vault, credential id and site.
  static func find(_ chosen: VaultPasskey, in opened: [VaultPasskey]) -> AutofillPasskey? {
    opened.first {
      $0.vault == chosen.vault && $0.passkey.credentialId == chosen.passkey.credentialId
        && HostMatch.normalize($0.passkey.rpId) == HostMatch.normalize(chosen.passkey.rpId) && $0.passkey.privateKey != nil
    }?.passkey
  }

  /// What a site gets back for a sign-in.
  struct Assertion {
    let authenticatorData: Data
    /// ES256, DER, over the authenticator data and the client data's hash.
    let signature: Data
  }

  /// Signs in with [passkey], which needs its key, for the client data whose SHA-256 is [clientDataHash].
  static func assert(_ passkey: AutofillPasskey, clientDataHash: Data) throws -> Assertion {
    guard let der = passkey.privateKey else { throw AutofillFormatError.field("privateKey") }
    let key = try P256.Signing.PrivateKey(derRepresentation: der)
    let authData = PasskeyBytes.assertionAuthData(rpId: passkey.rpId)
    let signed = PasskeyBytes.assertionSignedBytes(authData: authData, clientDataHash: clientDataHash)
    return Assertion(authenticatorData: authData, signature: try PasskeyBytes.sign(signed, with: key))
  }
}
