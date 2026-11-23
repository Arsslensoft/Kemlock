import CoreNFC
import Flutter
import Foundation
import XCTest

@testable import Runner

/// What the phone's side of `lib/platform/security_keys.dart` decides without a key: the
/// application a SELECT names, whether Info.plist declares it, what Core NFC's errors mean, and
/// the answers of the channel on a simulator, which has no NFC. Reading a key takes an iPhone and
/// a key (the design's Risks).
final class SecurityKeyChannelTests: XCTestCase {
  private let fido = Data([0xA0, 0x00, 0x00, 0x06, 0x47, 0x2F, 0x00, 0x01])

  /// [method] answered as Flutter would ask it, on the main thread.
  private func call(_ method: String, _ arguments: [String: Any] = [:], on channel: SecurityKeyChannel = SecurityKeyChannel()) async -> Any? {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        channel.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { continuation.resume(returning: $0) }
      }
    }
  }

  func testFindsTheApplicationAShortSelectNames() {
    XCTAssertEqual(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x08]) + fido), fido)
    XCTAssertEqual(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x08]) + fido + Data([0x00])), fido, "with Le")
    XCTAssertEqual(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x0C, 0x02, 0xD2, 0x76])), Data([0xD2, 0x76]), "whatever P2 says")
  }

  func testFindsTheApplicationAnExtendedSelectNames() {
    XCTAssertEqual(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x08]) + fido), fido)
    XCTAssertEqual(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x08]) + fido + Data([0x00, 0x00])), fido, "with Le")
  }

  func testNamesNoApplicationForOtherCommands() {
    // NFCCTAP_MSG, a SELECT by file identifier, GET RESPONSE
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x80, 0x10, 0x00, 0x00, 0x01, 0x04, 0x00])))
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x00, 0x00, 0x02, 0x3F, 0x00])))
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x00, 0xC0, 0x00, 0x00, 0x00])))
    // A SELECT by name with no name, with Le alone, and cut short
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00])))
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x00])))
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x00])))
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x08, 0xA0, 0x00])))
    XCTAssertNil(SecurityKeyApdu.selectedName(Data([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x08, 0xA0])))
    XCTAssertNil(SecurityKeyApdu.selectedName(Data()))
  }

  func testChecksAnApplicationAgainstTheDeclaredOnesInEitherCase() {
    XCTAssertTrue(SecurityKeyApdu.isDeclared(fido, in: ["A0000006472F0001"]))
    XCTAssertTrue(SecurityKeyApdu.isDeclared(fido, in: ["D27600012401", "a0000006472f0001"]))
    XCTAssertFalse(SecurityKeyApdu.isDeclared(fido, in: []))
    XCTAssertFalse(SecurityKeyApdu.isDeclared(fido, in: ["A0000006472F00"]), "not by its beginning")
    XCTAssertFalse(SecurityKeyApdu.isDeclared(Data([0xA0, 0x00, 0x00, 0x05, 0x27, 0x21, 0x01]), in: ["A0000006472F0001"]))
  }

  func testDeclaresTheFidoApplication() {
    XCTAssertTrue(SecurityKeyApdu.isDeclared(fido, in: SecurityKeyApdu.declared))
  }

  func testMapsWhatCoreNfcSays() {
    func nfc(_ code: NFCReaderError.Code) -> Error {
      NSError(domain: NFCReaderError.errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "The reader said no"])
    }
    for code in [
      NFCReaderError.Code.readerTransceiveErrorTagConnectionLost, .readerTransceiveErrorTagNotConnected,
      .readerTransceiveErrorRetryExceeded, .readerTransceiveErrorSessionInvalidated,
    ] {
      XCTAssertEqual(SecurityKeyError.from(nfc: nfc(code)), .removed)
    }
    XCTAssertEqual(SecurityKeyError.from(nfc: nfc(.readerTransceiveErrorTagResponseError)), .timeout)
    XCTAssertEqual(SecurityKeyError.from(nfc: nfc(.readerSessionInvalidationErrorSessionTimeout)), .timeout)
    XCTAssertEqual(SecurityKeyError.from(nfc: nfc(.readerSessionInvalidationErrorUserCanceled)), .cancelled)
    XCTAssertEqual(SecurityKeyError.from(nfc: nfc(.readerSessionInvalidationErrorSessionTerminatedUnexpectedly)), .failed("The reader said no"))
    XCTAssertEqual(SecurityKeyError.from(nfc: nfc(.readerSessionInvalidationErrorSystemIsBusy)), .failed("The reader said no"))
    XCTAssertEqual(SecurityKeyError.from(nfc: nfc(.readerErrorUnsupportedFeature)).code, "failed")
    XCTAssertEqual(SecurityKeyError.from(nfc: NSError(domain: "other", code: 100)).code, "failed")
    XCTAssertEqual(SecurityKeyError.from(nfcCode: 9999, description: "Unknown").message, "Unknown")
  }

  func testNamesTheCodesDartReads() {
    XCTAssertEqual(
      ["cancelled", "unavailable", "nfcOff", "denied", "removed", "timeout", "noApplication", "notDeclared", "failed"],
      [SecurityKeyError.cancelled, .unavailable, .nfcOff, .denied, .removed, .timeout, .noApplication, .notDeclared, .failed("x")].map(\.code)
    )
    XCTAssertNil(SecurityKeyError.removed.message)
    XCTAssertEqual(SecurityKeyError.failed("x").message, "x")
  }

  func testDescribesADeviceWithItsOneApduLink() throws {
    let key = SecurityKeyChannel.device("nfc:1", kind: "nfc", product: nil)
    XCTAssertEqual(key["device"] as? String, "nfc:1")
    XCTAssertNil(key["product"])
    XCTAssertEqual(key["needsPermission"] as? Bool, false)
    let link = try XCTUnwrap((key["links"] as? [[String: Any]])?.first)
    XCTAssertEqual(link["id"] as? String, "nfc:1")
    XCTAssertEqual(link["kind"] as? String, "nfc")
    XCTAssertEqual(link["extendedLength"] as? Bool, true)
    XCTAssertEqual(link["frameSize"] as? Int, 0)

    let card = SecurityKeyChannel.device("smartcard:2", kind: "smartcard", product: "A reader")
    XCTAssertEqual(card["product"] as? String, "A reader")
    XCTAssertEqual((card["links"] as? [[String: Any]])?.first?["kind"] as? String, "smartcard")
  }

  func testTellsWhatThePhoneCanReachAKeyWith() async throws {
    let answer = await call("capabilities")

    let capabilities = try XCTUnwrap(answer as? [String: Any])
    XCTAssertEqual(capabilities["nfc"] as? Bool, NFCTagReaderSession.readingAvailable)
    XCTAssertEqual(capabilities["nfcOn"] as? Bool, NFCTagReaderSession.readingAvailable)
    XCTAssertEqual(capabilities["usb"] as? Bool, false)
    XCTAssertEqual(capabilities["readsOnRequest"] as? Bool, true)
    XCTAssertNotNil(capabilities["smartcards"] as? Bool)
  }

  func testRefusesToReadWhereThereIsNoNfc() async throws {
    guard !NFCTagReaderSession.readingAvailable else { throw XCTSkip("This device reads NFC") }

    let began = await call("beginNfc", ["message": "Hold your key to the phone"])

    XCTAssertEqual((began as? FlutterError)?.code, "unavailable")
  }

  func testAnswersForALinkThatIsGone() async {
    let channel = SecurityKeyChannel()
    let apdu = FlutterStandardTypedData(bytes: Data([0x00, 0xA4, 0x04, 0x00, 0x08]) + fido)

    for link in ["nfc:1", "smartcard:9", ""] {
      let opened = await call("open", ["link": link], on: channel)
      XCTAssertEqual((opened as? FlutterError)?.code, "removed", link)
      let answer = await call("transceive", ["link": link, "data": apdu, "timeoutMs": 5000], on: channel)
      XCTAssertEqual((answer as? FlutterError)?.code, "removed", link)
      let closed = await call("close", ["link": link], on: channel)
      XCTAssertNil(closed, link)
    }
    let links = await call("requestPermission", ["device": "smartcard:9"], on: channel)
    XCTAssertEqual((links as? [Any])?.count, 0)
  }

  func testEndsNothingWhenNoSessionIsUp() async {
    let channel = SecurityKeyChannel()

    let message = await call("setNfcMessage", ["message": "Reading"], on: channel)
    let ended = await call("endNfc", ["error": NSNull()], on: channel)
    let failed = await call("endNfc", ["error": "No key"], on: channel)

    XCTAssertNil(message)
    XCTAssertNil(ended)
    XCTAssertNil(failed)
  }

  func testHasNoRawFrames() async {
    let written = await call("write", ["link": "nfc:1", "frames": [FlutterStandardTypedData(bytes: Data([1]))]])
    let read = await call("read", ["link": "nfc:1", "timeoutMs": 100])
    let unknown = await call("format")

    XCTAssertEqual((written as? FlutterError)?.code, "unavailable")
    XCTAssertEqual((read as? FlutterError)?.code, "unavailable")
    XCTAssertTrue((unknown as AnyObject?) === FlutterMethodNotImplemented)
  }
}
