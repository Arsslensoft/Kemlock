import Foundation
import XCTest

@testable import Runner

/// The redirect of an SSO sign-in is taken only when it is this sign-in's own (SsoCallback). The sheet itself is
/// the system's and is tried on a phone (the plan's task 13.4).
final class BrowserAuthChannelTests: XCTestCase {
  private let state = "abcdefghijklmnopqrstuvwxyz012345"

  func testARedirectWithTheStateIsTaken() throws {
    let url = try XCTUnwrap(URL(string: "kemlock://sso?code=one-time-code&state=\(state)"))
    XCTAssertEqual(SsoCallback.accept(url, state: state), url)
  }

  func testARedirectWithAnotherStateOrNoneIsDropped() throws {
    XCTAssertNil(SsoCallback.accept(try XCTUnwrap(URL(string: "kemlock://sso?code=c&state=another-sign-in-state-0000000000")), state: state))
    XCTAssertNil(SsoCallback.accept(try XCTUnwrap(URL(string: "kemlock://sso?code=c")), state: state))
  }

  func testAnotherSchemeOrHostIsDropped() throws {
    XCTAssertNil(SsoCallback.accept(try XCTUnwrap(URL(string: "otpauth://sso?code=c&state=\(state)")), state: state))
    XCTAssertNil(SsoCallback.accept(try XCTUnwrap(URL(string: "kemlock://other?code=c&state=\(state)")), state: state))
  }

  func testAStateThatIsOnlyAPrefixIsDropped() throws {
    XCTAssertNil(SsoCallback.accept(try XCTUnwrap(URL(string: "kemlock://sso?code=c&state=\(state)extra")), state: state))
    XCTAssertNil(SsoCallback.accept(try XCTUnwrap(URL(string: "kemlock://sso?code=c&state=\(state.dropLast())")), state: state))
  }

  func testAStateIsSixteenToTwoFiftySixUrlSafeCharacters() {
    XCTAssertTrue(SsoCallback.isValidState(state))
    XCTAssertFalse(SsoCallback.isValidState("short"))
    XCTAssertFalse(SsoCallback.isValidState(String(repeating: "x", count: 257)))
    XCTAssertFalse(SsoCallback.isValidState("has a space in it 0000"))
  }
}
