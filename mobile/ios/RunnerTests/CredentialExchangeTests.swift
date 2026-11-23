import AuthenticationServices
import Foundation
import XCTest

@testable import Runner

/// What Apple's Credential Exchange types become in CXF JSON (openspec: plan
/// add-credential-exchange, task 4.2): the example of the specification, decoded into
/// ASExportedCredentialData and encoded again, must still hold the credentials of each item that
/// mobile/test/fixtures/import/cxf/ios-roundtrip.json lists, which the Dart reader is held to as
/// well. That file is written by hand from the example; task 4.3 checks a real hand-off on a phone.
@available(iOS 26.0, *)
final class CredentialExchangeTests: XCTestCase {
  private static let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../test/fixtures/import/cxf")
    .standardizedFileURL

  /// The example with its file credential taken out, which Apple's enum has no case for.
  private func example() throws -> Data {
    var root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: Self.folder.appendingPathComponent("fido-example.json")))
        as? [String: Any])
    var accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
    for a in accounts.indices {
      var items = try XCTUnwrap(accounts[a]["items"] as? [[String: Any]])
      for i in items.indices {
        let credentials = try XCTUnwrap(items[i]["credentials"] as? [[String: Any]])
        items[i]["credentials"] = credentials.filter { $0["type"] as? String != "file" }
      }
      accounts[a]["items"] = items
    }
    root["accounts"] = accounts
    return try JSONSerialization.data(withJSONObject: root)
  }

  /// The credential types of each item, in order, as the expectation file lists them.
  private func summary(of json: Data) throws -> [[String: Any]] {
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    return try XCTUnwrap(root["accounts"] as? [[String: Any]]).map { account in
      let items = (account["items"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
        let types = (item["credentials"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        return ["title": item["title"] as? String ?? "", "types": types]
      }
      return ["items": items]
    }
  }

  func testTheExampleKeepsTheCredentialsOfEachItemThroughAppleTypes() throws {
    let decoded = try CredentialExchangeJSON.decode(try example())
    let encoded = try CredentialExchangeJSON.encode(decoded)
    let expected = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: Self.folder.appendingPathComponent("ios-roundtrip.json")))
        as? [String: Any])
    let expectedAccounts = try XCTUnwrap(expected["accounts"] as? [[String: Any]])
    let got = try summary(of: encoded)

    XCTAssertEqual(got.count, expectedAccounts.count)
    for (account, want) in zip(got, expectedAccounts) {
      let items = try XCTUnwrap(account["items"] as? [[String: Any]])
      let wanted = try XCTUnwrap(want["items"] as? [[String: Any]])
      XCTAssertEqual(items.count, wanted.count)
      for (item, wantItem) in zip(items, wanted) {
        XCTAssertEqual(item["title"] as? String, wantItem["title"] as? String)
        XCTAssertEqual(item["types"] as? [String], wantItem["types"] as? [String], "\(item["title"] ?? "")")
      }
    }
  }

  func testTheHeaderIsWrittenWithTheSpecificationsNames() throws {
    let encoded = try CredentialExchangeJSON.encode(try CredentialExchangeJSON.decode(try example()))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    let version = try XCTUnwrap(root["version"] as? [String: Any])
    XCTAssertEqual(version["major"] as? Int, 1)
    XCTAssertEqual(version["minor"] as? Int, 0)
    XCTAssertEqual(root["exporterRpId"] as? String, "exporter.example.com")
    XCTAssertEqual(root["exporterDisplayName"] as? String, "Exporter app")
    XCTAssertEqual((root["timestamp"] as? NSNumber)?.intValue, 1_705_228_800)
  }

  func testBase64urlWritesNoPaddingAndReadsWithOrWithout() {
    let bytes = Data([0xfb, 0xff, 0xfe, 0x01])
    XCTAssertEqual(CredentialExchangeJSON.base64url(bytes), "-__-AQ")
    XCTAssertEqual(CredentialExchangeJSON.bytes(fromBase64url: "-__-AQ"), bytes)
    XCTAssertEqual(CredentialExchangeJSON.bytes(fromBase64url: "-__-AQ=="), bytes)
    XCTAssertNil(CredentialExchangeJSON.bytes(fromBase64url: "not base64!"))
  }

  // MARK: Export (task 8.3)

  /// A payload written the way `formats/cxf_writer.dart` writes one: a login with its code and
  /// note, and a card. Written by hand from the writer's code, in test/fixtures/export.
  private func writerSample() throws -> Data {
    let folder = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("../../test/fixtures/export")
      .standardizedFileURL
    return try Data(contentsOf: folder.appendingPathComponent("writer-sample.json"))
  }

  /// Every string in a JSON value, at any depth.
  private func strings(in value: Any) -> Set<String> {
    switch value {
    case let text as String: return [text]
    case let list as [Any]: return list.reduce(into: Set<String>()) { $0.formUnion(strings(in: $1)) }
    case let object as [String: Any]:
      return object.values.reduce(into: Set<String>()) { $0.formUnion(strings(in: $1)) }
    default: return []
    }
  }

  func testWhatTheWriterMakesDecodesIntoAppleTypesAndEncodesBackWithItsSecrets() throws {
    let sample = try writerSample()
    let decoded = try CredentialExchangeJSON.decode(sample)
    let encoded = try CredentialExchangeJSON.encode(decoded)

    let before = try XCTUnwrap(JSONSerialization.jsonObject(with: sample) as? [String: Any])
    let after = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    // The items, in order, with their credential types
    let want = try summary(of: sample)
    let got = try summary(of: encoded)
    XCTAssertEqual(got.count, want.count)
    for (account, wanted) in zip(got, want) {
      let items = try XCTUnwrap(account["items"] as? [[String: Any]])
      let wantedItems = try XCTUnwrap(wanted["items"] as? [[String: Any]])
      XCTAssertEqual(items.count, wantedItems.count)
      for (item, wantedItem) in zip(items, wantedItems) {
        XCTAssertEqual(item["title"] as? String, wantedItem["title"] as? String)
        XCTAssertEqual(item["types"] as? [String], wantedItem["types"] as? [String], "\(item["title"] ?? "")")
      }
    }

    // What the person is moving survives the trip: the secrets and the values, to the character
    let kept = strings(in: after)
    for value in [
      "ada", "hunter2-sample", "JBSWY3DPEHPK3PXP", "sample note", "https://larkspur.example", "4111111111111111",
      "Ada Lovelace", "123", "2030-04", "Work",
    ] {
      XCTAssertTrue(kept.contains(value), "\(value) was lost")
    }
    XCTAssertEqual(after["exporterRpId"] as? String, before["exporterRpId"] as? String)
    XCTAssertEqual(after["exporterDisplayName"] as? String, "Kemlock")
  }

  func testTheFormatVersionTheImporterAnswersIsTheOneTheDataCarries() throws {
    let decoded = try CredentialExchangeJSON.decode(try writerSample(), formatVersion: .v1)
    let version = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try CredentialExchangeJSON.encode(decoded)) as? [String: Any]
    )["version"] as? [String: Any]

    XCTAssertEqual(version?["major"] as? Int, 1)
    XCTAssertEqual(version?["minor"] as? Int, 0)
  }
}
