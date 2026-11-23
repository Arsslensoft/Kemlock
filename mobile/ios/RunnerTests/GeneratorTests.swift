import Foundation
import XCTest

@testable import Runner

/// The Swift generator and rules parser (ios/Shared/Generator.swift), held to
/// the same passwords as the Dart app and the Android service through
/// mobile/test/fixtures/generator/cases.json, which is never regenerated
/// (openspec: add-passwords, task 6.3).
final class GeneratorTests: XCTestCase {
  private static let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../test/fixtures/generator/cases.json")
    .standardizedFileURL

  private func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.utf8)
    return stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16)! }
  }

  func testMakesEveryRandomPasswordOfTheSharedCases() throws {
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
    var checked = 0
    for item in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
      // The passphrases are the app's alone: AutoFill makes random passwords
      guard item["kind"] as? String == "random" else { continue }
      let c = try XCTUnwrap(item["choices"] as? [String: Any])
      let choices = PasswordChoices(
        length: c["length"] as? Int ?? defaultPasswordLength,
        capitals: c["capitals"] as? Bool ?? true,
        digits: c["digits"] as? Bool ?? true,
        symbols: c["symbols"] as? Bool ?? true,
        avoidLookAlikes: c["avoidLookAlikes"] as? Bool ?? true
      )
      let rules = (item["rules"] as? String).map(PasswordRules.parse)
      let source = FixedByteSource(hex(try XCTUnwrap(item["bytes"] as? String)))

      let made = try generatePassword(source, choices, rules: rules)

      XCTAssertEqual(made, item["password"] as? String, item["name"] as? String ?? "")
      checked += 1
    }
    XCTAssertEqual(checked, 9)
  }

  func testDrawsBelowANumberWithoutFavouringTheLowValues() throws {
    // 250 and up would favour 0 to 5 below 10: they are drawn again
    XCTAssertEqual(try pickBelow(FixedByteSource([250, 255, 13]), 10), 3)
    // Over 256 values take two bytes, most significant first
    XCTAssertEqual(try pickBelow(FixedByteSource([1, 2]), 1000), 0x0102 % 1000)
    XCTAssertThrowsError(try pickBelow(FixedByteSource([255]), 10))
  }

  func testMakesTheDefaultsWithEverySetAndNoLookAlike() throws {
    for _ in 0..<200 {
      let password = try generatePassword(SecureByteSource())
      XCTAssertEqual(password.count, 20)
      for set in [lowerChars, upperChars, digitChars, generatorSymbols] {
        XCTAssertTrue(password.contains { set.contains($0) }, password)
      }
      XCTAssertFalse(password.contains { lookAlikes.contains($0) }, password)
    }
  }

  func testFollowsASiteThatLimitsTheLength() throws {
    let rules = PasswordRules.parse("minlength: 8; maxlength: 16; required: lower; required: upper; required: digit")
    for _ in 0..<50 {
      let password = try generatePassword(SecureByteSource(), rules: rules)
      XCTAssertEqual(password.count, 16)
      XCTAssertTrue(password.contains(where: \.isLowercase) && password.contains(where: \.isUppercase) && password.contains(where: \.isNumber), password)
    }
  }

  func testLeavesOutTheSymbolsASiteRefuses() throws {
    let rules = PasswordRules.parse("allowed: lower, upper, digit")
    for _ in 0..<50 {
      let password = try generatePassword(SecureByteSource(), PasswordChoices(symbols: true), rules: rules)
      XCTAssertTrue(password.allSatisfy { $0.isLetter || $0.isNumber }, password)
    }
  }

  func testIgnoresRulesThatContradictEachOther() {
    XCTAssertEqual(passwordPlan(PasswordChoices(), PasswordRules.parse("minlength: 30; maxlength: 12")), passwordPlan(PasswordChoices()))
  }

  func testReadsTheRulesLanguage() {
    let rules = PasswordRules.parse("minlength: 10; required: []-]; required: lower, digit; allowed: [_]; max-consecutive: 2; bogus: 3")

    XCTAssertEqual(rules.minLength, 10)
    XCTAssertEqual(rules.required, ["]-", lowerChars + digitChars])
    XCTAssertEqual(rules.allowed, "_")
    XCTAssertEqual(rules.maxConsecutive, 2)
    XCTAssertTrue(PasswordRules.parse("bogus; ;").isEmpty)
    // A site's own rules may separate classes with a tab, or end on an open bracket
    XCTAssertEqual(PasswordRules.parse("required: lower,\tdigit").required, [lowerChars + digitChars])
    XCTAssertEqual(PasswordRules.parse("required: upper; allowed: [").allowed, "")
  }

  // ─── iOS 26.2's requests (openspec: add-passwords, task 6.6) ───────────────

  func testTakesTheFieldsRulesBeforeApplesForTheSite() {
    XCTAssertEqual(LoginProvider.rules(field: "maxlength: 12", quirks: "maxlength: 30")?.maxLength, 12)
    XCTAssertEqual(LoginProvider.rules(field: nil, quirks: "maxlength: 30")?.maxLength, 30)
    // A field whose rules say nothing this parser knows leaves Apple's
    XCTAssertEqual(LoginProvider.rules(field: "bogus: 1", quirks: "minlength: 9")?.minLength, 9)
    XCTAssertNil(LoginProvider.rules(field: "", quirks: nil))
    XCTAssertNil(LoginProvider.rules(field: nil, quirks: nil))
  }

  func testAnswersAStrongPasswordThatMeetsTheRequestsRules() throws {
    let rules = LoginProvider.rules(field: "minlength: 8; maxlength: 16; required: lower; required: upper; required: digit", quirks: nil)
    let password = try LoginProvider.strongPassword(rules: rules)

    XCTAssertEqual(password.count, 16)
    XCTAssertEqual(try LoginProvider.strongPassword(rules: nil).count, defaultPasswordLength)
    // The same bytes make what the shared cases' generator makes
    let bytes = [UInt8](repeating: 7, count: 64) + (0..<200).map { UInt8($0) }
    XCTAssertEqual(try LoginProvider.strongPassword(rules: rules, source: FixedByteSource(bytes)), try generatePassword(FixedByteSource(bytes), rules: rules))
  }

  func testCallsAPasswordOfLettersAndDigitsAlphanumeric() throws {
    XCTAssertTrue(LoginProvider.isAlphanumeric("pBGQ57ENVAoLH2eVTbXX"))
    XCTAssertFalse(LoginProvider.isAlphanumeric("6_2TG2roD&W4AznSzKsR"))
    XCTAssertFalse(LoginProvider.isAlphanumeric("é1abcdef"))
    XCTAssertTrue(LoginProvider.isAlphanumeric(try LoginProvider.strongPassword(rules: PasswordRules.parse("allowed: lower, upper, digit"))))
  }
}
