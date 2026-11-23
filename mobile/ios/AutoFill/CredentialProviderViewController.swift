import AuthenticationServices
import LocalAuthentication
import SwiftUI
import UIKit

/// Kemlock's AutoFill extension (openspec: add-passwords, the code-autofill and password-autofill specs): fills a one-time
/// code or a login from the copy the app wrote, after Face ID or Touch ID,
/// without opening the app. A suggestion above the keyboard fills its account
/// or login straight away; the key icon and the edit menu's AutoFill show the
/// list, with those for the website first. It also saves new passkeys for
/// the vaults that take them, into their inboxes, and signs in with the
/// passkeys of the copies and those it saved, after Face ID or Touch ID.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let store = AutofillStore.shared()
  private var hosting: UIHostingController<AnyView>?

  /// A list opened with Face ID or Touch ID is on screen: the accounts' codes, or the logins
  /// with their passwords.
  private var listIsOpen = false

  override func viewDidLoad() {
    super.viewDidLoad()
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(hostLeft), name: NSNotification.Name.NSExtensionHostDidEnterBackground, object: nil)
    // Again on the way back, should the extension have been suspended before it heard the first
    center.addObserver(self, selector: #selector(hostLeft), name: NSNotification.Name.NSExtensionHostWillEnterForeground, object: nil)
  }

  /// The app the list was opened in went to the background, as it does when the phone locks. The
  /// list was opened for whoever passed Face ID or Touch ID, and the passcode alone never opens
  /// it: it doesn't wait there for the next person to unlock the phone. The request ends, and
  /// the copies it had open go with it.
  @objc private func hostLeft() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.listIsOpen else { return }
      self.listIsOpen = false
      self.show(AnyView(WaitingView()))
      self.cancel(.userCanceled)
    }
  }

  // ─── A suggestion above the keyboard ───────────────────────────────────────

  /// The copy is behind biometrics, which can't be asked for without a screen: a code, a
  /// login or a passkey picked above the keyboard or in the passkey sheet always comes back
  /// to prepareInterfaceToProvideCredential.
  override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
    extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
  }

  override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
    if credentialRequest.type == .passkeyAssertion { return signIn(credentialRequest) }
    if credentialRequest.type == .password { return fillLogin(credentialRequest) }
    guard credentialRequest.type == .oneTimeCode, let record = AutofillRecord(credentialRequest.credentialIdentity.recordIdentifier) else {
      return cancel(.credentialIdentityNotFound)
    }
    show(AnyView(WaitingView()))
    unlock { [weak self] context in
      guard let self else { return }
      let copies = (try? self.store.openCopies(context: context)) ?? []
      let account = copies.first { $0.vault == record.vault }?.accounts.first { $0.id == record.account }
      guard let account, let code = OneTimeCode.code(for: account, at: Self.now()) else {
        return self.show(message: Text("failed.body"))
      }
      self.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }
  }

  // ─── The key icon, and the edit menu ───────────────────────────────────────

  override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    showList(hosts: HostMatch.hosts(of: serviceIdentifiers)) { [weak self] code in
      self?.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }
  }

  override func prepareInterfaceForUserChoosingTextToInsert() {
    showList(hosts: []) { [weak self] code in
      self?.extensionContext.completeRequest(withTextToInsert: code)
    }
  }

  private func showList(hosts: [String], fill: @escaping (String) -> Void) {
    show(AnyView(WaitingView()))
    unlock { [weak self] context in
      guard let self else { return }
      let copies: [AutofillCopy]
      do {
        copies = try self.store.openCopies(context: context)
      } catch {
        return self.show(message: Text("failed.body"))
      }
      var picked = Set<String>()
      if let host = hosts.first {
        for copy in copies {
          for pick in self.store.openPicks(copy.vault, context: context) where pick.host == host {
            picked.insert("\(copy.vault)/\(pick.account)")
          }
        }
      }
      let model = AccountListModel(copies: copies, host: hosts.first, picked: picked)
      self.listIsOpen = true
      self.show(
        AnyView(
          AccountListView(
            model: model,
            onPick: { row, remember in
              guard let code = OneTimeCode.code(for: row.account, at: Self.now()) else { return }
              if remember, let host = model.host {
                try? self.store.remember(.web(host, account: row.account.id), vault: row.vault)
                IdentitySync.refresh(self.store)
              }
              self.listIsOpen = false
              fill(code)
            },
            onCancel: { [weak self] in
              self?.listIsOpen = false
              self?.cancel(.userCanceled)
            }
          )
        )
      )
    }
  }

  // ─── Filling a login ───────────────────────────────────────────────────────

  /// A login iOS suggested above the keyboard, which its identity names: Face ID or Touch ID,
  /// then its username and password from the copy.
  private func fillLogin(_ credentialRequest: any ASCredentialRequest) {
    guard let record = AutofillRecord(credentialRequest.credentialIdentity.recordIdentifier) else { return cancel(.credentialIdentityNotFound) }
    show(AnyView(WaitingView()))
    unlock(.login) { [weak self] context in
      guard let self else { return }
      let copies = (try? self.store.openCopies(context: context)) ?? []
      guard let login = LoginListModel.login(record, in: copies) else { return self.show(message: Text("login.failed.body")) }
      self.complete(login)
    }
  }

  /// Kemlock picked from the key icon, or from Passwords above the keyboard: after Face ID or
  /// Touch ID, every login, the website's first, with search. On a website no login names, the
  /// list says Kemlock doesn't know it, and the pick can be remembered for it.
  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    let host = HostMatch.websites(of: serviceIdentifiers).first
    show(AnyView(WaitingView()))
    unlock(.login) { [weak self] context in
      guard let self else { return }
      let copies: [AutofillCopy]
      do {
        copies = try self.store.openCopies(context: context)
      } catch {
        return self.show(message: Text("login.failed.body"))
      }
      var picked = Set<String>()
      if let host {
        for copy in copies {
          for pick in self.store.openPicks(copy.vault, context: context) where pick.host == host {
            picked.insert("\(copy.vault)/\(pick.account)")
          }
        }
      }
      let logins = copies.flatMap { copy in copy.logins.map { VaultLogin(vault: copy.vault, login: $0) } }
      let model = LoginListModel(logins: logins, host: host, picked: picked)
      // Closed with the code list when the host app goes to the background (hostLeft)
      self.listIsOpen = true
      self.show(
        AnyView(
          LoginListView(
            model: model,
            onPick: { row, remember in
              if remember, let host = model.host {
                try? self.store.remember(.web(host, account: row.login.id), vault: row.vault, login: true)
                IdentitySync.refresh(self.store)
              }
              self.listIsOpen = false
              self.complete(row.login)
            },
            onCancel: { [weak self] in
              self?.listIsOpen = false
              self?.cancel(.userCanceled)
            }
          )
        )
      )
    }
  }

  /// Fills [login]'s username and password; one without either fills it empty.
  private func complete(_ login: AutofillLogin) {
    let credential = ASPasswordCredential(user: login.username ?? "", password: login.password ?? "")
    extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
  }

  // ─── Signing in with a passkey ─────────────────────────────────────────────

  /// A passkey iOS suggested for the site, which its identity names.
  private func signIn(_ credentialRequest: any ASCredentialRequest) {
    guard let request = credentialRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
      let record = AutofillRecord(identity.recordIdentifier)
    else { return cancel(.credentialIdentityNotFound) }
    guard keyStillOpens(.passkey) else { return }
    let chosen = AutofillPasskey(
      credentialId: identity.credentialID, rpId: identity.relyingPartyIdentifier, userHandle: identity.userHandle, userName: identity.userName,
      privateKey: nil)
    signIn(with: VaultPasskey(vault: record.vault, passkey: chosen), clientDataHash: request.clientDataHash)
  }

  /// Kemlock picked in the passkey sheet: the site's passkeys, only those the request
  /// allows when it names some, from a list when there are several.
  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
    guard keyStillOpens(.passkey) else { return }
    let site = requestParameters.relyingPartyIdentifier
    let offered = PasskeyProvider.passkeys(store.passkeyNames(), for: site, allowed: requestParameters.allowedCredentials)
    guard let first = offered.first else {
      return show(message: Text(String(format: NSLocalizedString("passkey.none.body", comment: ""), site)))
    }
    guard offered.count > 1 else { return signIn(with: first, clientDataHash: requestParameters.clientDataHash) }
    let names = Dictionary(store.passkeyVaults().map { ($0.vault, vaultName($0)) }, uniquingKeysWith: { first, _ in first })
    show(
      AnyView(
        PasskeyListView(
          passkeys: offered,
          site: site,
          vaultNames: names,
          onPick: { [weak self] chosen in self?.signIn(with: chosen, clientDataHash: requestParameters.clientDataHash) },
          onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )
      )
    )
  }

  /// Face ID or Touch ID, then the [chosen] passkey's key from the copy or the extension's
  /// own record, and the signature. A key that doesn't open says to open Kemlock once.
  private func signIn(with chosen: VaultPasskey, clientDataHash: Data) {
    show(AnyView(WaitingView()))
    unlock(.passkey) { [weak self] context in
      guard let self else { return }
      let opened = (try? self.store.openPasskeys(context: context)) ?? []
      guard let passkey = PasskeyProvider.find(chosen, in: opened), let assertion = try? PasskeyProvider.assert(passkey, clientDataHash: clientDataHash)
      else { return self.show(message: Text("passkey.failed.body")) }
      let credential = ASPasskeyAssertionCredential(
        userHandle: passkey.userHandle,
        relyingParty: passkey.rpId,
        signature: assertion.signature,
        clientDataHash: clientDataHash,
        authenticatorData: assertion.authenticatorData,
        credentialID: passkey.credentialId
      )
      self.extensionContext.completeAssertionRequest(using: credential)
    }
  }

  // ─── A new passkey ─────────────────────────────────────────────────────────

  /// A site or an app asks to save a passkey in Kemlock. It is refused when
  /// the site takes no ES256 key or lists a passkey Kemlock holds for it;
  /// otherwise the vault is chosen when several take passkeys, Face ID or
  /// Touch ID is asked for, and the new passkey is sealed to the vault's
  /// inbox and beside the copy before the site gets it.
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    guard let request = registrationRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
    else { return cancel(.failed) }
    let refusal = PasskeyProvider.refusal(
      algorithms: request.supportedAlgorithms.map(\.rawValue),
      excluded: request.excludedCredentials?.map(\.credentialID) ?? [],
      rpId: identity.relyingPartyIdentifier,
      held: store.passkeyNames()
    )
    switch refusal {
    case .algorithm: return cancel(.failed, reason: NSLocalizedString("passkey.algorithm", comment: ""))
    case .excluded: return cancel(.matchedExcludedCredential)
    case nil: break
    }
    guard keyStillOpens(.newPasskey) else { return }
    let vaults = store.passkeyVaults()
    guard let first = vaults.first else { return show(message: Text("passkey.off.body")) }
    guard vaults.count > 1 else { return register(request, identity: identity, in: first) }
    show(
      AnyView(
        VaultChoiceView(
          vaults: vaults,
          site: identity.relyingPartyIdentifier,
          user: identity.userName,
          onPick: { [weak self] vault in self?.register(request, identity: identity, in: vault) },
          onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )
      )
    )
  }

  private func register(_ request: ASPasskeyCredentialRequest, identity: ASPasskeyCredentialIdentity, in vault: PasskeyVault) {
    show(AnyView(WaitingView()))
    unlock(.newPasskey) { [weak self] _ in
      guard let self else { return }
      let made = PasskeyProvider.register(rpId: identity.relyingPartyIdentifier, userName: identity.userName, userHandle: identity.userHandle)
      do {
        try self.store.save(made.record, in: vault, publicKey: AutofillKey.find().flatMap(SecKeyCopyPublicKey))
      } catch {
        return self.show(message: Text("passkey.saveFailed.body"))
      }
      let credential = ASPasskeyRegistrationCredential(
        relyingParty: identity.relyingPartyIdentifier,
        clientDataHash: request.clientDataHash,
        credentialID: made.credentialId,
        attestationObject: made.attestationObject
      )
      // Suggested from now on, before the app has moved it into the vault
      IdentitySync.refresh(self.store) {
        DispatchQueue.main.async { self.extensionContext.completeRegistrationRequest(using: credential) }
      }
    }
  }

  // ─── A strong password, from iOS 26.2 ──────────────────────────────────────

  /// iOS asks for a strong password for a new-password field: one made here with the defaults,
  /// held to the rules the request hands over, with no prompt, while a vault has suggesting on.
  /// Nothing is kept yet: a password filled comes back as a save request.
  @available(iOS 26.2, *)
  override func performWithoutUserInteraction(generatePasswordsRequest: ASGeneratePasswordsRequest) {
    answer(generatePasswordsRequest)
  }

  /// The extension says it shows no screen to generate on (SupportsGeneratePasswordCredentialsWithUI),
  /// so iOS shows its own; should it ask for Kemlock's anyway, the answer is the same.
  @available(iOS 26.2, *)
  override func prepareInterface(for generatePasswordsRequest: ASGeneratePasswordsRequest) {
    answer(generatePasswordsRequest)
  }

  @available(iOS 26.2, *)
  private func answer(_ request: ASGeneratePasswordsRequest) {
    guard store.suggestsPasswords() else { return cancel(.failed) }
    let rules = LoginProvider.rules(field: request.passwordFieldPasswordRules, quirks: request.passwordRulesFromQuirks)
    guard let password = try? LoginProvider.strongPassword(rules: rules) else { return cancel(.failed) }
    let kind: ASGeneratedPassword.Kind = LoginProvider.isAlphanumeric(password) ? .alphanumeric : .strong
    extensionContext.completeGeneratePasswordRequest(results: [ASGeneratedPassword(kind: kind, value: password)], completionHandler: nil)
  }

  // ─── Saving a login, from iOS 26.2 ─────────────────────────────────────────

  /// iOS asks to save the login a form sent, or a password it filled from Kemlock's generator
  /// before the form is sent. It is sealed to a vault's inbox, with no screen and no biometrics,
  /// when the vault is known: the one whose login it changes, the only one that saves logins,
  /// or, for a generated password, the one used last. Otherwise the person picks the vault.
  @available(iOS 26.2, *)
  override func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
    guard let save = decide(savePasswordRequest) else { return cancel(.failed) }
    guard let vault = save.vault else { return cancel(.userInteractionRequired) }
    keep(save.record, in: vault, shown: false)
  }

  /// The vault choice of IosSave.dc.html: the site, the username and the password hidden, then
  /// the vaults that save logins, the one used last picked first.
  @available(iOS 26.2, *)
  override func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
    guard let save = decide(savePasswordRequest) else { return show(message: Text("save.off.body")) }
    if let vault = save.vault { return keep(save.record, in: vault, shown: true) }
    guard case let .login(_, name, username, _, site, _, _, _) = save.record else { return cancel(.failed) }
    show(
      AnyView(
        LoginSaveView(
          site: site,
          name: name,
          username: username,
          vaults: save.vaults,
          onPick: { [weak self] vault in self?.keep(save.record, in: vault, shown: true) },
          onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )
      )
    )
  }

  /// What [request] keeps, from the indexes and the vault records alone.
  @available(iOS 26.2, *)
  private func decide(_ request: ASSavePasswordRequest) -> LoginProvider.Save? {
    let service = request.serviceIdentifier
    let names = store.loginNames()
    return LoginProvider.save(
      site: HostMatch.websites(of: [service]).first,
      appName: service.displayName ?? request.title ?? service.identifier,
      username: request.credential.user,
      password: request.credential.password,
      generatedFilled: request.event == .generatedPasswordFilled,
      generated: request.passwordKind != nil,
      vaults: store.loginVaults(),
      logins: names.logins,
      picks: names.picks,
      at: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)),
      newId: { UUID().uuidString.lowercased() }
    )
  }

  /// Seals [record] to [vault]'s inbox, for the app to take in when the vault is next opened.
  /// Saved logins are suggested once the app has them and writes the copy again.
  @available(iOS 26.2, *)
  private func keep(_ record: LoginRecord, in vault: PasskeyVault, shown: Bool) {
    do {
      try store.saveLogin(record, in: vault)
    } catch {
      if shown { show(message: Text("save.failed.body")) } else { cancel(.failed) }
      return
    }
    extensionContext.completeSavePasswordRequest(completionHandler: nil)
  }

  // ─── Turned on in Settings ─────────────────────────────────────────────────

  /// Kemlock was just turned on in AutoFill's settings. Identities saved while it was off
  /// were refused, and the app saves them again only when it next writes a copy, so the
  /// suggestions above the keyboard stayed missing until then. The indexes the app wrote are
  /// still here and need no Face ID, so the identities are saved from them now.
  override func prepareInterfaceForExtensionConfiguration() {
    show(AnyView(WaitingView()))
    IdentitySync.refresh(store) {
      DispatchQueue.main.async { [weak self] in self?.extensionContext.completeExtensionConfigurationRequest() }
    }
  }

  // ─── Unlocking ─────────────────────────────────────────────────────────────

  /// What Face ID or Touch ID is asked for, which picks the prompt and the messages.
  private enum Purpose {
    case code
    case login
    case passkey
    case newPasskey

    var reason: String {
      switch self {
      case .code: NSLocalizedString("unlock.reason", comment: "")
      case .login: NSLocalizedString("login.use.reason", comment: "")
      case .passkey: NSLocalizedString("passkey.use.reason", comment: "")
      case .newPasskey: NSLocalizedString("passkey.save.reason", comment: "")
      }
    }

    var empty: LocalizedStringKey {
      switch self {
      case .code: return "empty.body"
      case .login: return "login.empty.body"
      case .passkey, .newPasskey: return "passkey.off.body"
      }
    }

    var stale: LocalizedStringKey {
      switch self {
      case .code: return "stale.body"
      case .login: return "login.stale.body"
      case .passkey, .newPasskey: return "passkey.stale.body"
      }
    }
  }

  /// Whether the key still opens the copies. A key that biometrics changed since, or a missing
  /// one, opens nothing: its files go, and the person is told to open Kemlock, which makes a
  /// new key when it writes the copy again. The passkeys waiting in the inboxes stay. Face ID or
  /// Touch ID locked after too many failed tries is no change: nothing goes, and the person is
  /// told to unlock the phone with its passcode.
  private func keyStillOpens(_ purpose: Purpose) -> Bool {
    guard store.vaults().isEmpty || store.keyIsCurrent() else {
      guard !store.keyWaitsForPasscode() else {
        show(message: Text("lockedOut.body"))
        return false
      }
      store.reset()
      IdentitySync.clear()
      show(message: Text(purpose.stale))
      return false
    }
    return true
  }

  /// Face ID or Touch ID once, then [then] with the context that answers the key's prompt.
  /// Biometrics alone: the passcode isn't offered in their place.
  private func unlock(_ purpose: Purpose = .code, then: @escaping (LAContext) -> Void) {
    guard !store.vaults().isEmpty else { return show(message: Text(purpose.empty)) }
    guard keyStillOpens(purpose) else { return }
    let context = LAContext()
    context.localizedCancelTitle = NSLocalizedString("cancel", comment: "")
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      if AutofillKey.isLockout(error) { return show(message: Text("lockedOut.body")) }
      return show(message: Text("noBiometrics.body"))
    }
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: purpose.reason) { [weak self] ok, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        guard ok else { return self.cancel(.userCanceled) }
        then(context)
      }
    }
  }

  // ─── The screen ────────────────────────────────────────────────────────────

  private func show(_ view: AnyView) {
    if let hosting {
      hosting.rootView = view
      return
    }
    let controller = UIHostingController(rootView: view)
    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    self.view.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: self.view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
    ])
    controller.didMove(toParent: self)
    hosting = controller
  }

  private func show(message: Text) {
    show(AnyView(MessageView(message: message, onClose: { [weak self] in self?.cancel(.userCanceled) })))
  }

  /// Ends the request with [code], and the [reason] iOS shows when there is one.
  private func cancel(_ code: ASExtensionError.Code, reason: String? = nil) {
    let userInfo = reason.map { [ASExtensionLocalizedFailureReasonErrorKey: $0] }
    extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue, userInfo: userInfo))
  }

  private static func now() -> Int64 { Int64(Date().timeIntervalSince1970.rounded(.down)) }
}
