import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import XCTest

@testable import Runner

/// The Swift side of autofill (ios/Shared), held to the same codes as the
/// Dart app through mobile/test/fixtures/autofill/codes.json, which carries
/// the codes the TypeScript app made.
final class AutofillTests: XCTestCase {
  private static let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../test/fixtures/autofill/codes.json")
    .standardizedFileURL

  private func loadFixture() throws -> (copy: AutofillCopy, codes: [[String: Any]]) {
    let data = try Data(contentsOf: Self.fixture)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let copy = try AutofillCopy(json: JSONSerialization.data(withJSONObject: try XCTUnwrap(root["copy"])))
    return (copy, try XCTUnwrap(root["codes"] as? [[String: Any]]))
  }

  // ─── Codes ─────────────────────────────────────────────────────────────────

  func testMakesTheCodesTheTypeScriptAppMade() throws {
    let (copy, codes) = try loadFixture()
    XCTAssertGreaterThan(codes.count, 80)
    let accounts = Dictionary(uniqueKeysWithValues: copy.accounts.map { ($0.id, $0) })
    for item in codes {
      let id = try XCTUnwrap(item["account"] as? String)
      let account = try XCTUnwrap(accounts[id])
      let nowSec = try XCTUnwrap(item["nowSec"] as? NSNumber).int64Value
      XCTAssertEqual(OneTimeCode.code(for: account, at: nowSec), item["code"] as? String, "\(item)")
    }
  }

  func testMakesTheCodesOfRFC6238() throws {
    // RFC 6238, appendix B, at 59 s and 1111111109 s.
    let key = Data("12345678901234567890".utf8)
    let account = AutofillAccount(id: "a", issuer: "", label: "", kind: .totp, algorithm: "SHA1", digits: 8, period: 30, key: key, domains: [])
    XCTAssertEqual(OneTimeCode.code(for: account, at: 59), "94287082")
    XCTAssertEqual(OneTimeCode.code(for: account, at: 1_111_111_109), "07081804")
  }

  func testMakesNoCodeForAnAlgorithmTheAppNeverHandsOver() {
    let account = AutofillAccount(id: "a", issuer: "", label: "", kind: .totp, algorithm: "MD5", digits: 6, period: 30, key: Data([1]), domains: [])
    XCTAssertNil(OneTimeCode.code(for: account, at: 0))
  }

  func testCountsTheSecondsLeftInAWindow() {
    XCTAssertEqual(OneTimeCode.secondsRemaining(period: 30, at: 0), 30)
    XCTAssertEqual(OneTimeCode.secondsRemaining(period: 30, at: 29), 1)
    XCTAssertEqual(OneTimeCode.secondsRemaining(period: 30, at: 30), 30)
  }

  // ─── Hosts ─────────────────────────────────────────────────────────────────

  func testFillsOnTheDomainAndItsSubdomains() {
    XCTAssertTrue(HostMatch.matches(host: "github.com", domain: "github.com"))
    XCTAssertTrue(HostMatch.matches(host: "gist.github.com", domain: "github.com"))
    XCTAssertTrue(HostMatch.matches(host: "GitHub.com.", domain: "github.com"))
  }

  func testNeverFillsOnALookAlike() {
    XCTAssertFalse(HostMatch.matches(host: "github.com.evil.io", domain: "github.com"))
    XCTAssertFalse(HostMatch.matches(host: "evilgithub.com", domain: "github.com"))
    XCTAssertFalse(HostMatch.matches(host: "com", domain: "github.com"))
    XCTAssertFalse(HostMatch.matches(host: "", domain: "github.com"))
    XCTAssertFalse(HostMatch.matches(host: "github.com", domain: ""))
  }

  func testFillsAnExactOnlyDomainOnThatHostAlone() {
    XCTAssertTrue(HostMatch.matches(host: "okta.com", domain: "=okta.com"))
    XCTAssertFalse(HostMatch.matches(host: "evil.okta.com", domain: "=okta.com"))
    XCTAssertTrue(HostMatch.matches(host: "acme.okta.com", domains: ["=acme.okta.com", "=okta.com"]))
  }

  func testKnowsThePageOfAnHttpsAddressOnly() {
    XCTAssertEqual(HostMatch.hosts(of: [ASCredentialServiceIdentifier(identifier: "https://GitHub.com/login", type: .URL)]), ["github.com"])
    XCTAssertEqual(HostMatch.hosts(of: [ASCredentialServiceIdentifier(identifier: "http://github.com/login", type: .URL)]), [])
    XCTAssertEqual(HostMatch.hosts(of: [ASCredentialServiceIdentifier(identifier: "github.com", type: .domain)]), ["github.com"])
  }

  // ─── Formats ───────────────────────────────────────────────────────────────

  func testReadsTheCopyTheAppWrites() throws {
    let json = """
      {"v":1,"vault":"main","accounts":[{"id":"a1","issuer":"GitHub","label":"alice","kind":"totp",
      "algorithm":"SHA1","digits":6,"period":30,"key":"SGVsbG8h3q2+7w==","domains":["github.com"]}]}
      """
    let copy = try AutofillCopy(json: Data(json.utf8))
    XCTAssertEqual(copy.vault, "main")
    XCTAssertEqual(copy.accounts.first?.domains, ["github.com"])
    XCTAssertEqual(copy.accounts.first?.key, Data(base64Encoded: "SGVsbG8h3q2+7w=="))
  }

  func testRefusesAnotherVersion() {
    XCTAssertThrowsError(try AutofillCopy(json: Data(#"{"v":2,"vault":"main","accounts":[]}"#.utf8))) {
      XCTAssertEqual($0 as? AutofillFormatError, .version(2))
    }
    XCTAssertThrowsError(try AutofillCopy(json: Data(#"{"vault":"main","accounts":[]}"#.utf8)))
    XCTAssertThrowsError(try AutofillIndex(json: Data(#"{"v":0,"vault":"main","accounts":[]}"#.utf8)))
    XCTAssertThrowsError(try AutofillCopy(json: Data("not json".utf8))) { XCTAssertEqual($0 as? AutofillFormatError, .notJSON) }
  }

  func testAnIndexForPasskeysAloneNamesNoAccounts() {
    XCTAssertTrue(AutofillIndex.namesAccounts(Data(#"{"v":1,"vault":"main","accounts":[{"id":"a1","issuer":"GitHub","domains":[]}]}"#.utf8)))
    XCTAssertFalse(AutofillIndex.namesAccounts(Data(#"{"v":1,"vault":"main","accounts":[],"passkeys":[]}"#.utf8)))
    XCTAssertFalse(AutofillIndex.namesAccounts(Data(#"{"v":2,"vault":"main","accounts":[{"id":"a1","issuer":"GitHub","domains":[]}]}"#.utf8)))
    XCTAssertFalse(AutofillIndex.namesAccounts(nil))
  }

  func testRefusesAnAccountOfAnotherKind() {
    let json = #"{"v":1,"vault":"main","accounts":[{"id":"h","issuer":"","label":"","kind":"hotp","algorithm":"SHA1","digits":6,"period":30,"key":"AA==","domains":[]}]}"#
    XCTAssertThrowsError(try AutofillCopy(json: Data(json.utf8))) { XCTAssertEqual($0 as? AutofillFormatError, .field("kind")) }
  }

  func testReadsSuggestionRecords() {
    XCTAssertEqual(AutofillRecord("main/a1"), AutofillRecord(vault: "main", account: "a1"))
    XCTAssertEqual(AutofillRecord("0123456789ab/x/y"), AutofillRecord(vault: "0123456789ab", account: "x/y"))
    XCTAssertNil(AutofillRecord("../etc/a1"))
    XCTAssertNil(AutofillRecord("main/"))
    XCTAssertNil(AutofillRecord(nil))
  }

  func testKeepsFileNamesInsideTheFolder() {
    XCTAssertTrue(AutofillStore.isVaultId("main"))
    XCTAssertTrue(AutofillStore.isVaultId("0123456789ab"))
    XCTAssertFalse(AutofillStore.isVaultId("../main"))
    XCTAssertFalse(AutofillStore.isVaultId("0123456789AB"))
    XCTAssertFalse(AutofillStore.isVaultId(""))
  }

  // ─── Backups ───────────────────────────────────────────────────────────────

  func testKeepsTheFolderOutOfBackupsEachTimeItIsMade() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = AutofillStore(folder: base.appendingPathComponent("Autofill", isDirectory: true))
    // A new URL each time, so the answer is read from the disk
    func outOfBackups() throws -> Bool? {
      try URL(fileURLWithPath: store.folder.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    // The inbox is beside the folder and stays in backups: writing to it doesn't make the folder
    try store.write(Data([1]), to: store.inboxURL("main", credentialId: Data([1, 2, 3])))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path))

    try store.write(Data(#"{"v":1,"vault":"main","accounts":[]}"#.utf8), to: store.indexURL("main"))
    XCTAssertEqual(try outOfBackups(), true)

    // Biometrics changed: the folder goes, and is made again by the next write
    store.removeAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path))
    try store.write(Data([1]), to: store.madeURL("main", credentialId: Data([4, 5, 6])))
    XCTAssertEqual(try outOfBackups(), true)
  }

  // ─── Encryption ────────────────────────────────────────────────────────────

  func testOpensWhatItEncryptsToAKey() throws {
    var error: Unmanaged<CFError>?
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
    let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    let plain = Data(#"{"v":1,"vault":"main","accounts":[]}"#.utf8)

    let sealed = try AutofillKey.encrypt(plain, to: key)

    XCTAssertNotEqual(sealed, plain)
    XCTAssertEqual(try AutofillKey.decrypt(sealed, with: key), plain)
  }

  // ─── Logins (openspec: add-passwords, task 6.2) ────────────────────────────

  func testReadsTheLoginsOfACopyWithTheirPasswords() throws {
    let json = """
      {"v":1,"vault":"main","accounts":[],"logins":[
      {"id":"l1","name":"Larkspur Mail","username":"ada@example.org","password":"hunter2","domains":["larkspur.example","=sso.okta.com"]},
      {"id":"l2","name":"Bank","password":"x","domains":[]},
      {"name":"No id","password":"x","domains":["a.example"]},
      {"id":"l3","name":"No domains","password":"x"},
      {"id":"l4","name":"Odd domains","password":"x","domains":[1]},
      "not a login"]}
      """

    let copy = try AutofillCopy(json: Data(json.utf8))

    // An entry this version can't read is left out, not the whole copy
    XCTAssertEqual(
      copy.logins,
      [
        AutofillLogin(id: "l1", name: "Larkspur Mail", username: "ada@example.org", password: "hunter2", domains: ["larkspur.example", "=sso.okta.com"]),
        AutofillLogin(id: "l2", name: "Bank", password: "x", domains: []),
      ])
    XCTAssertEqual(copy.logins.map(\.shownName), ["ada@example.org", "Bank"])
  }

  func testReadsACopyFromBeforePasswordsAsHoldingNoLogins() throws {
    let copy = try AutofillCopy(json: Data(#"{"v":1,"vault":"main","accounts":[],"logins":"none"}"#.utf8))

    XCTAssertEqual(copy.logins, [])
    XCTAssertEqual(try AutofillCopy(json: Data(#"{"v":1,"vault":"main","accounts":[]}"#.utf8)).logins, [])
  }

  func testAnIndexKeepsNoPasswordEvenWhenGivenOne() throws {
    let json = #"{"v":1,"vault":"main","accounts":[],"logins":[{"id":"l1","name":"Larkspur","username":"ada","password":"hunter2","domains":["larkspur.example"]}]}"#

    let index = try AutofillIndex(json: Data(json.utf8))

    XCTAssertEqual(index.logins, [AutofillLogin(id: "l1", name: "Larkspur", username: "ada", domains: ["larkspur.example"])])
    XCTAssertTrue(AutofillIndex.holdsLogins(Data(json.utf8)))
    XCTAssertFalse(AutofillIndex.holdsLogins(Data(#"{"v":1,"vault":"main","accounts":[],"logins":[]}"#.utf8)))
    XCTAssertFalse(AutofillIndex.holdsLogins(Data(#"{"v":2,"vault":"main","accounts":[],"logins":[{"id":"l1","domains":[]}]}"#.utf8)))
    XCTAssertFalse(AutofillIndex.holdsLogins(nil))
  }

  private let codesIndex = Data(#"{"v":1,"vault":"main","accounts":[{"id":"a1","issuer":"GitHub","domains":["github.com"]}]}"#.utf8)
  private let loginsIndex = Data(#"{"v":1,"vault":"main","accounts":[],"logins":[{"id":"l1","name":"Larkspur","domains":["larkspur.example"]}]}"#.utf8)
  private let bothCopy = Data(
    #"{"v":1,"vault":"main","accounts":[{"id":"a1","issuer":"GitHub","label":"","kind":"totp","algorithm":"SHA1","digits":6,"period":30,"key":"AA==","domains":[]}],"logins":[{"id":"l1","name":"Larkspur","domains":["larkspur.example"]}]}"#
      .utf8)

  func testKeepsALoginsPicksInTheClearWhileTheIndexHoldsLoginsAlone() {
    let picks: [AutofillPick] = [.web("sso.acme.test", account: "a1"), .web("mail.acme.test", account: "l1")]

    // Names on: every pick stays
    XCTAssertEqual(AutofillPlainPicks.named(picks, copy: bothCopy, index: codesIndex), picks)
    // Names off, passwords on: the login's stays, the code's goes
    XCTAssertEqual(AutofillPlainPicks.named(picks, copy: bothCopy, index: loginsIndex), [.web("mail.acme.test", account: "l1")])
    // Both off, as for passkeys alone: none stays
    XCTAssertEqual(AutofillPlainPicks.named(picks, copy: bothCopy, index: Data(#"{"v":1,"vault":"main","accounts":[]}"#.utf8)), [])
  }

  func testRemembersALoginsPickInTheClearOnlyWhileTheIndexHoldsLogins() {
    let code = AutofillPick.web("acme.test", account: "a1")
    let login = AutofillPick.web("acme.test", account: "l1")

    XCTAssertEqual(AutofillPlainPicks.remembering(login, login: true, in: [], index: loginsIndex), [login])
    XCTAssertNil(AutofillPlainPicks.remembering(code, login: false, in: [], index: loginsIndex))
    XCTAssertNil(AutofillPlainPicks.remembering(login, login: true, in: [], index: Data(#"{"v":1,"vault":"main","accounts":[]}"#.utf8)))
    XCTAssertNil(AutofillPlainPicks.remembering(login, login: true, in: [], index: nil))
  }

  func testAWebsiteKeepsOneCodeAndOneLoginPickedThere() throws {
    let index = Data(
      #"{"v":1,"vault":"main","accounts":[{"id":"a1","issuer":"Acme","domains":[]}],"logins":[{"id":"l1","name":"Acme","domains":[]},{"id":"l2","name":"Acme","domains":[]}]}"#
        .utf8)
    let picks: [AutofillPick] = [.web("acme.test", account: "a1"), .web("acme.test", account: "l1"), .web("other.test", account: "l1")]

    let afterLogin = try XCTUnwrap(AutofillPlainPicks.remembering(.web("acme.test", account: "l2"), login: true, in: picks, index: index))
    let afterCode = try XCTUnwrap(AutofillPlainPicks.remembering(.web("acme.test", account: "a2"), login: false, in: picks, index: index))

    XCTAssertEqual(afterLogin, [.web("acme.test", account: "a1"), .web("other.test", account: "l1"), .web("acme.test", account: "l2")])
    XCTAssertEqual(afterCode, [.web("acme.test", account: "l1"), .web("other.test", account: "l1"), .web("acme.test", account: "a2")])
  }

  func testSuggestsEachLoginOnItsDomainsAndPickedHostsByUsername() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Password identities are synced from iOS 18") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AutofillStore(folder: folder)
    let index = """
      {"v":1,"vault":"main","accounts":[],"logins":[
      {"id":"l1","name":"Larkspur","username":"ada@example.org","domains":["larkspur.example","=sso.okta.com"]},
      {"id":"l2","name":"Bank","domains":["bank.example"]}]}
      """
    try store.write(Data(index.utf8), to: store.indexURL("main"))
    try store.write(Data([1]), to: store.copyURL("main"))
    try store.write(try AutofillPlainPicks(picks: [.web("sso.acme.test", account: "l1"), .web("x.test", account: "gone")]).json(), to: store.plainPicksURL("main"))

    let identities = IdentitySync.passwordIdentities(in: store)

    XCTAssertEqual(identities.map(\.serviceIdentifier.identifier), ["larkspur.example", "sso.okta.com", "bank.example", "sso.acme.test"])
    XCTAssertEqual(identities.map(\.user), ["ada@example.org", "ada@example.org", "Bank", "ada@example.org"])
    XCTAssertEqual(identities.compactMap(\.recordIdentifier), ["main/l1", "main/l1", "main/l2", "main/l1"])
    // The logins name no service for codes
    XCTAssertEqual(IdentitySync.identities(in: store).count, 0)
  }

  // ─── Filling logins (openspec: add-passwords, task 6.5) ────────────────────

  private func login(_ id: String, _ name: String, username: String? = nil, domains: [String], vault: String = "main") -> VaultLogin {
    VaultLogin(vault: vault, login: AutofillLogin(id: id, name: name, username: username, password: "pw-\(id)", domains: domains))
  }

  func testOffersALoginOnItsSiteAndSubdomainsFirst() {
    let logins = [
      login("l1", "Larkspur Mail", username: "ada@example.org", domains: ["larkspur.example"]),
      login("l2", "Bank", domains: ["bank.example"]),
      login("l3", "Acme", domains: ["=acme.okta.com"]),
      login("l4", "Larkspur Mail", username: "work@example.org", domains: ["larkspur.example"], vault: "0123456789ab"),
    ]

    let model = LoginListModel(logins: logins, host: "accounts.larkspur.example", picked: [])

    // Every login, by name then username, those of the site above them
    XCTAssertEqual(model.rows.map(\.record), ["main/l3", "main/l2", "main/l1", "0123456789ab/l4"])
    XCTAssertEqual(model.suggested.map(\.record), ["main/l1", "0123456789ab/l4"])
  }

  func testNeverOffersALoginOnALookAlikeOrAnotherTenant() {
    let logins = [login("l1", "Larkspur", domains: ["larkspur.example"]), login("l2", "Acme", domains: ["=acme.okta.com"])]

    for host in ["larkspur.example.evil.test", "evillarkspur.example", "evil.okta.com", "okta.com"] {
      XCTAssertEqual(LoginListModel(logins: logins, host: host, picked: []).suggested, [], host)
    }
    XCTAssertEqual(LoginListModel(logins: logins, host: "acme.okta.com", picked: []).suggested.map(\.record), ["main/l2"])
    // No website, as from the edit menu: nothing is the site's
    XCTAssertEqual(LoginListModel(logins: logins, host: nil, picked: []).suggested, [])
  }

  func testOffersALoginPickedForASiteItDoesntName() {
    let logins = [login("l1", "Larkspur", domains: ["larkspur.example"]), login("l2", "Bank", domains: [])]

    let model = LoginListModel(logins: logins, host: "sso.acme.test", picked: ["main/l2", "0123456789ab/l1"])

    XCTAssertEqual(model.suggested.map(\.record), ["main/l2"])
  }

  func testSearchesLoginsByNameUsernameAndWebsite() {
    let rows = [login("l1", "Larkspur Mail", username: "ada@example.org", domains: ["larkspur.example"]), login("l2", "Bank", domains: ["bank.example"])]

    XCTAssertEqual(LoginListModel.found(rows, query: "MAIL").map(\.login.id), ["l1"])
    XCTAssertEqual(LoginListModel.found(rows, query: "ada@").map(\.login.id), ["l1"])
    XCTAssertEqual(LoginListModel.found(rows, query: "bank.ex").map(\.login.id), ["l2"])
    XCTAssertEqual(LoginListModel.found(rows, query: "  ").map(\.login.id), ["l1", "l2"])
    XCTAssertEqual(LoginListModel.found(rows, query: "nothing"), [])
  }

  func testFillsTheLoginASuggestionNamesFromItsOwnVault() throws {
    let copy = try AutofillCopy(
      json: Data(#"{"v":1,"vault":"main","accounts":[],"logins":[{"id":"l1","name":"Larkspur","username":"ada","password":"hunter2","domains":[]}]}"#.utf8))
    let other = AutofillCopy(vault: "0123456789ab", accounts: [], logins: [AutofillLogin(id: "l1", name: "Other", password: "x", domains: [])])

    XCTAssertEqual(LoginListModel.login(AutofillRecord(vault: "main", account: "l1"), in: [other, copy])?.password, "hunter2")
    XCTAssertNil(LoginListModel.login(AutofillRecord(vault: "main", account: "l2"), in: [other, copy]))
    XCTAssertNil(LoginListModel.login(AutofillRecord(vault: "aaaaaaaaaaaa", account: "l1"), in: [other, copy]))
  }

  func testMatchesOnlyTheWebsitesIOSNames() throws {
    let identifiers = [
      ASCredentialServiceIdentifier(identifier: "https://Accounts.Larkspur.example/login", type: .URL),
      ASCredentialServiceIdentifier(identifier: "larkspur.example", type: .domain),
    ]
    XCTAssertEqual(HostMatch.websites(of: identifiers), ["accounts.larkspur.example", "larkspur.example"])

    // From iOS 26.2 an app without a website is named by its App ID, which is no host
    guard #available(iOS 26.2, *) else { throw XCTSkip("App service identifiers come with iOS 26.2") }
    XCTAssertEqual(HostMatch.websites(of: [ASCredentialServiceIdentifier(identifier: "ABCDE12345.example.larkspur", type: .app)]), [])
  }

  // ─── Saving logins (openspec: add-passwords, task 6.6) ─────────────────────

  private static let point = Data([4] + [UInt8](repeating: 1, count: 64))
  private let personal = PasskeyVault(vault: "main", inboxKey: AutofillTests.point, name: "Personal", writtenAt: 9, takes: VaultTakes(logins: true))
  private let work = PasskeyVault(vault: "0123456789ab", inboxKey: AutofillTests.point, name: "Work", writtenAt: 5, takes: VaultTakes(logins: true))

  private func save(
    site: String? = "www.larkspur.example", appName: String = "Larkspur", username: String = " Ada@Example.org ", password: String = "hunter2",
    generatedFilled: Bool = false, vaults: [PasskeyVault], logins: [VaultLogin] = [], picks: [String: [AutofillPick]] = [:]
  ) -> LoginProvider.Save? {
    LoginProvider.save(
      site: site, appName: appName, username: username, password: password, generatedFilled: generatedFilled, generated: false, vaults: vaults,
      logins: logins, picks: picks, at: 1_795_300_000_000, newId: { "new-id" })
  }

  func testSavesANewLoginToTheOnlyVaultThatSavesWithNoScreen() throws {
    let saved = try XCTUnwrap(save(vaults: [personal]))

    XCTAssertEqual(saved.vault, personal)
    XCTAssertFalse(saved.update)
    XCTAssertEqual(
      saved.record,
      .login(
        id: "new-id", name: "larkspur.example", username: "Ada@Example.org", password: "hunter2", site: "www.larkspur.example", app: nil,
        generated: false, at: 1_795_300_000_000))
  }

  func testAsksWhichVaultForANewLoginWhenTwoSave() throws {
    let saved = try XCTUnwrap(save(vaults: [personal, work]))

    XCTAssertNil(saved.vault)
    XCTAssertEqual(saved.vaults.map(\.vault), ["main", "0123456789ab"])
  }

  func testUpdatesTheLoginOfTheSameSiteAndUsernameInItsOwnVault() throws {
    let held = login("l9", "Larkspur Mail", username: "ada@example.org", domains: ["larkspur.example"], vault: "0123456789ab")
    let other = login("l8", "Larkspur Mail", username: "bob@example.org", domains: ["larkspur.example"])

    let saved = try XCTUnwrap(save(site: "accounts.larkspur.example", vaults: [personal, work], logins: [other, held]))

    // No screen: the vault is the one whose login it changes, and the login keeps its id and name
    XCTAssertEqual(saved.vault, work)
    XCTAssertTrue(saved.update)
    XCTAssertEqual(
      saved.record,
      .login(
        id: "l9", name: "Larkspur Mail", username: "Ada@Example.org", password: "hunter2", site: "accounts.larkspur.example", app: nil,
        generated: false, at: 1_795_300_000_000))
  }

  func testUpdatesALoginPickedForTheSite() throws {
    let held = login("l9", "SSO", username: "ada@example.org", domains: [])

    let saved = try XCTUnwrap(save(site: "sso.acme.test", vaults: [personal, work], logins: [held], picks: ["main": [.web("sso.acme.test", account: "l9")]]))

    XCTAssertEqual(saved.vault, personal)
    XCTAssertTrue(saved.update)
  }

  func testNeverUpdatesALoginOfALookAlikeSite() throws {
    let held = login("l9", "Larkspur Mail", username: "ada@example.org", domains: ["larkspur.example"])

    let saved = try XCTUnwrap(save(site: "larkspur.example.evil.test", vaults: [personal], logins: [held]))

    XCTAssertFalse(saved.update)
    guard case let .login(id, name, _, _, _, _, _, _) = saved.record else { return XCTFail("not a login") }
    XCTAssertEqual(id, "new-id")
    XCTAssertEqual(name, "larkspur.example.evil.test")
  }

  func testSavesAnAppsLoginByItsNameAndUpdatesItThere() throws {
    let first = try XCTUnwrap(save(site: nil, appName: "Larkspur Mail", vaults: [personal]))
    guard case let .login(_, name, _, _, site, _, _, _) = first.record else { return XCTFail("not a login") }
    XCTAssertEqual(name, "Larkspur Mail")
    XCTAssertNil(site)

    // Once the app has it, the next save in that app changes it rather than adding another
    let held = login("l9", "Larkspur Mail", username: "ada@example.org", domains: [])
    let again = try XCTUnwrap(save(site: nil, appName: "Larkspur Mail", vaults: [personal, work], logins: [held]))
    XCTAssertTrue(again.update)
    XCTAssertEqual(again.vault, personal)
    // A login of a website isn't an app's
    let web = login("l7", "Larkspur Mail", username: "ada@example.org", domains: ["larkspur.example"])
    XCTAssertFalse(try XCTUnwrap(save(site: nil, appName: "Larkspur Mail", vaults: [personal], logins: [web])).update)
    XCTAssertNil(save(site: nil, appName: "", vaults: [personal]))
  }

  func testKeepsAPasswordIOSFilledFromTheGeneratorInTheVaultUsedLast() throws {
    let saved = try XCTUnwrap(save(generatedFilled: true, vaults: [personal, work]))

    XCTAssertEqual(saved.vault, personal)
    XCTAssertEqual(saved.record, .generated(password: "hunter2", site: "www.larkspur.example", at: 1_795_300_000_000))
  }

  func testSavesNothingWithoutAPasswordOrAVaultThatSaves() {
    XCTAssertNil(save(password: "", vaults: [personal]))
    XCTAssertNil(save(vaults: []))
  }

  func testWritesTheLoginToTheVaultsInboxForTheApp() throws {
    let (store, base) = PasskeyTests.temporaryStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let inboxKey = P256.KeyAgreement.PrivateKey()
    let vault = PasskeyVault(vault: "main", inboxKey: inboxKey.publicKey.x963Representation, name: nil, writtenAt: 1, takes: VaultTakes(logins: true))
    try store.write(Data([1]), to: store.copyURL("main"))
    try store.write(try vault.json(), to: store.passkeyVaultURL("main"))
    let index = #"{"v":1,"vault":"main","accounts":[],"logins":[{"id":"l9","name":"Larkspur","username":"ada","domains":["larkspur.example"]}]}"#
    try store.write(Data(index.utf8), to: store.indexURL("main"))

    let names = store.loginNames()
    let saved = try XCTUnwrap(
      LoginProvider.save(
        site: "larkspur.example", appName: "", username: "ADA", password: "new", generatedFilled: false, generated: true, vaults: store.loginVaults(),
        logins: names.logins, picks: names.picks, at: 5, newId: { "new-id" }))
    try store.saveLogin(saved.record, in: try XCTUnwrap(saved.vault))

    let file = try XCTUnwrap(store.inbox("main").first)
    XCTAssertTrue(file.name.hasPrefix("login-"))
    XCTAssertEqual(
      try LoginInbox.open(Data(file.content.utf8), with: inboxKey),
      .login(id: "l9", name: "Larkspur", username: "ADA", password: "new", site: "larkspur.example", app: nil, generated: true, at: 5))
  }

  // ─── Strings (openspec: add-passwords, task 6.7) ───────────────────────────

  private func extensionStrings(_ language: String) throws -> [String: String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../AutoFill/\(language).lproj/Localizable.strings").standardizedFileURL
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    return try XCTUnwrap((text as NSString).propertyListFromStringsFileFormat() as? [String: String], language)
  }

  /// The format placeholders of [text], in order: a translation that drops one shows the wrong text, or crashes.
  private func placeholders(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "%[0-9$]*[@a-zA-Z%]")  // swiftlint:disable:this force_try
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
  }

  func testEveryStringOfTheExtensionHasItsFrenchPlaceholdersAndAll() throws {
    let en = try extensionStrings("en")
    let fr = try extensionStrings("fr")

    XCTAssertEqual(Set(fr.keys).subtracting(en.keys), [], "French strings with no English")
    XCTAssertEqual(Set(en.keys).subtracting(fr.keys), [], "English strings with no French")
    for (key, text) in en {
      XCTAssertEqual(placeholders(fr[key] ?? text), placeholders(text), key)
    }
    // The passwords' strings among them
    for key in ["login.use.reason", "login.stale.body", "logins.unknownHost", "save.title", "save.to", "save.opened"] {
      XCTAssertNotNil(en[key], key)
    }
  }

  // ─── Biometrics ────────────────────────────────────────────────────────────

  func testTellsLockedBiometricsFromChangedOnes() {
    XCTAssertTrue(AutofillKey.isLockout(NSError(domain: LAError.errorDomain, code: LAError.biometryLockout.rawValue)))
    XCTAssertFalse(AutofillKey.isLockout(NSError(domain: LAError.errorDomain, code: LAError.biometryNotEnrolled.rawValue)))
    XCTAssertFalse(AutofillKey.isLockout(NSError(domain: NSCocoaErrorDomain, code: LAError.biometryLockout.rawValue)))
    XCTAssertFalse(AutofillKey.isLockout(nil))
  }

  // ─── Suggestions ───────────────────────────────────────────────────────────

  func testSuggestsEachAccountOnItsDomainsAndPickedHostsByIssuer() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("One-time code identities need iOS 18") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AutofillStore(folder: folder)
    try store.write(Data(#"{"v":1,"vault":"main","accounts":[{"id":"a1","issuer":"Okta","domains":["=acme.okta.com","=okta.com"]}]}"#.utf8), to: store.indexURL("main"))
    try store.write(Data([1]), to: store.copyURL("main"))
    try store.write(try AutofillPlainPicks(picks: [.web("sso.acme.test", account: "a1")]).json(), to: store.plainPicksURL("main"))

    let identities = IdentitySync.identities(in: store)

    XCTAssertEqual(identities.map(\.serviceIdentifier.identifier), ["acme.okta.com", "okta.com", "sso.acme.test"])
    XCTAssertEqual(Set(identities.map(\.label)), ["Okta"])
    XCTAssertEqual(Set(identities.compactMap(\.recordIdentifier)), ["main/a1"])
  }
}
