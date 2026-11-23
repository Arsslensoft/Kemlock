import AuthenticationServices
import Foundation

/// Keeps what iOS suggests above the keyboard in step with the indexes:
/// one one-time code identity per account and domain, and per website it
/// was picked for, named by the issuer, one passkey identity per
/// passkey, by its site and user name, and one password identity per login
/// and domain, and per website it was picked for, by its username. Nothing
/// without an index, so a vault whose suggestions mustn't name the service,
/// and whose passkeys and passwords are off, puts nothing here.
@available(iOS 18.0, *)
enum IdentitySync {
  /// The password identities the indexes' logins and their plaintext picks give.
  static func passwordIdentities(in store: AutofillStore) -> [ASPasswordCredentialIdentity] {
    var identities: [ASPasswordCredentialIdentity] = []
    var seen = Set<String>()
    for index in store.indexes() {
      func add(_ host: String, _ login: AutofillLogin) {
        let domain = HostMatch.normalize(host.hasPrefix("=") ? String(host.dropFirst()) : host)
        let record = VaultLogin(vault: index.vault, login: login).record
        guard !domain.isEmpty, seen.insert("\(record) \(domain)").inserted else { return }
        identities.append(
          ASPasswordCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
            user: login.shownName,
            recordIdentifier: record
          )
        )
      }
      let logins = Dictionary(index.logins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      for login in index.logins {
        for domain in login.domains { add(domain, login) }
      }
      for pick in store.plainPicks(index.vault) {
        if let host = pick.host, let login = logins[pick.account] { add(host, login) }
      }
    }
    return identities
  }

  /// The passkey identities: the indexes' passkeys and those the extension made.
  static func passkeyIdentities(in store: AutofillStore) -> [ASPasskeyCredentialIdentity] {
    store.passkeyNames().map { entry in
      ASPasskeyCredentialIdentity(
        relyingPartyIdentifier: entry.passkey.rpId,
        userName: entry.passkey.name,
        credentialID: entry.passkey.credentialId,
        userHandle: entry.passkey.userHandle,
        recordIdentifier: entry.record
      )
    }
  }

  /// The identities the store's indexes and plaintext picks give.
  static func identities(in store: AutofillStore) -> [ASOneTimeCodeCredentialIdentity] {
    var identities: [ASOneTimeCodeCredentialIdentity] = []
    var seen = Set<String>()
    func add(_ host: String, issuer: String, record: String) {
      let domain = HostMatch.normalize(host.hasPrefix("=") ? String(host.dropFirst()) : host)
      guard !domain.isEmpty, seen.insert("\(record) \(domain)").inserted else { return }
      identities.append(
        ASOneTimeCodeCredentialIdentity(
          serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
          label: issuer,
          recordIdentifier: record
        )
      )
    }
    for index in store.indexes() {
      let issuers = Dictionary(index.accounts.map { ($0.id, $0.issuer) }, uniquingKeysWith: { first, _ in first })
      for entry in index.accounts {
        for domain in entry.domains { add(domain, issuer: entry.issuer, record: "\(index.vault)/\(entry.id)") }
      }
      for pick in store.plainPicks(index.vault) {
        if let host = pick.host, let issuer = issuers[pick.account] { add(host, issuer: issuer, record: "\(index.vault)/\(pick.account)") }
      }
    }
    return identities
  }

  /// Replaces what iOS suggests with what [store] holds, when Kemlock is on in AutoFill's settings.
  static func refresh(_ store: AutofillStore = .shared(), completion: (() -> Void)? = nil) {
    let identityStore = ASCredentialIdentityStore.shared
    identityStore.getState { state in
      guard state.isEnabled else {
        completion?()
        return
      }
      let identities: [any ASCredentialIdentity] = self.identities(in: store) + passkeyIdentities(in: store) + passwordIdentities(in: store)
      if identities.isEmpty {
        identityStore.removeAllCredentialIdentities { _, _ in completion?() }
      } else {
        identityStore.replaceCredentialIdentities(identities) { _, _ in completion?() }
      }
    }
  }

  /// Removes everything iOS suggests from Kemlock.
  static func clear(completion: (() -> Void)? = nil) {
    ASCredentialIdentityStore.shared.removeAllCredentialIdentities { _, _ in completion?() }
  }
}

/// A suggestion's record: the vault, and the account or the login it fills,
/// or the passkey's credential id in base64url.
struct AutofillRecord: Equatable {
  let vault: String
  let account: String

  init(vault: String, account: String) {
    self.vault = vault
    self.account = account
  }

  /// `<vault>/<account>`, as the identities carry it.
  init?(_ identifier: String?) {
    guard let identifier, let slash = identifier.firstIndex(of: "/") else { return nil }
    vault = String(identifier[..<slash])
    account = String(identifier[identifier.index(after: slash)...])
    guard AutofillStore.isVaultId(vault), !account.isEmpty else { return nil }
  }
}
