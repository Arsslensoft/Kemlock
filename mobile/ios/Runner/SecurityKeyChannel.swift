import CoreNFC
import CryptoTokenKit
import Flutter
import Foundation

/// Why the phone could not reach a security key or carry a message to it, as
/// `lib/platform/security_keys.dart` reads the error codes. `nfcOff`, `denied` and `noApplication`
/// are never made on iPhone; they are here so both platforms name the same codes.
enum SecurityKeyError: Error, Equatable {
  /// The person closed the system's NFC sheet.
  case cancelled
  /// The phone cannot read over the link asked for.
  case unavailable
  case nfcOff
  case denied
  /// The key left the NFC field or was unplugged, or its link is no longer the live one.
  case removed
  /// The key gave no answer in time, or the reader session ran out.
  case timeout
  case noApplication
  /// The application's identifier is not in Info.plist's list, so Core NFC would refuse it.
  case notDeclared
  case failed(String)

  var code: String {
    switch self {
    case .cancelled: return "cancelled"
    case .unavailable: return "unavailable"
    case .nfcOff: return "nfcOff"
    case .denied: return "denied"
    case .removed: return "removed"
    case .timeout: return "timeout"
    case .noApplication: return "noApplication"
    case .notDeclared: return "notDeclared"
    case .failed: return "failed"
    }
  }

  var message: String? {
    if case .failed(let message) = self { return message }
    return nil
  }

  /// What an error from a Core NFC session or command means.
  static func from(nfc error: Error) -> SecurityKeyError {
    let error = error as NSError
    guard error.domain == NFCReaderError.errorDomain else { return .failed(error.localizedDescription) }
    return from(nfcCode: error.code, description: error.localizedDescription)
  }

  /// What the `NFCReaderError` code [code] means, for a command and for a session's end alike.
  static func from(nfcCode code: Int, description: String) -> SecurityKeyError {
    switch NFCReaderError.Code(rawValue: code) {
    case .readerTransceiveErrorTagConnectionLost, .readerTransceiveErrorTagNotConnected,
      .readerTransceiveErrorRetryExceeded, .readerTransceiveErrorSessionInvalidated:
      return .removed
    case .readerTransceiveErrorTagResponseError, .readerSessionInvalidationErrorSessionTimeout:
      return .timeout
    case .readerSessionInvalidationErrorUserCanceled:
      return .cancelled
    default:
      // A session that ended unexpectedly or a busy system among them
      return .failed(description)
    }
  }
}

/// The little of ISO 7816-4 the phone's side has to read: Core NFC lets an app select only the
/// applications its Info.plist lists, so a SELECT is checked before it is sent.
enum SecurityKeyApdu {
  /// Info.plist's key for the identifiers Core NFC lets the app select.
  static let declaredKey = "com.apple.developer.nfc.readersession.iso7816.select-identifiers"

  /// The identifiers this build declares.
  static var declared: [String] { Bundle.main.object(forInfoDictionaryKey: declaredKey) as? [String] ?? [] }

  /// The application identifier [apdu] selects when it is a SELECT by name (`00 A4 04`), with a
  /// short or an extended length; nil for any other command and for one that is cut short.
  static func selectedName(_ apdu: Data) -> Data? {
    let bytes = [UInt8](apdu)
    guard bytes.count > 5, bytes[0] == 0x00, bytes[1] == 0xA4, bytes[2] == 0x04 else { return nil }
    var start = 5
    var length = Int(bytes[4])
    if length == 0 {
      // Extended: a zero byte, then the length on two bytes
      guard bytes.count > 7 else { return nil }
      length = Int(bytes[5]) << 8 | Int(bytes[6])
      start = 7
    }
    guard length > 0, bytes.count >= start + length else { return nil }
    return Data(bytes[start..<start + length])
  }

  /// Whether [identifiers], written in hexadecimal in either case, hold [name].
  static func isDeclared(_ name: Data, in identifiers: [String]) -> Bool {
    let hex = name.map { String(format: "%02X", $0) }.joined()
    return identifiers.contains { $0.uppercased() == hex }
  }
}

/// The smartcards plugged into the phone's USB-C port, through CryptoTokenKit's slots (iOS 16
/// and later, with the `com.apple.security.smartcard` entitlement). A slot is named by a counter,
/// never by anything the card says of itself. Used on the main thread only.
@available(iOS 16.0, *)
final class SmartCardSlots {
  private let manager: TKSmartCardSlotManager
  /// A card became valid in a watched slot: the device map to send.
  var arrived: (([String: Any]) -> Void)?
  /// The card or its slot went: the device's id.
  var left: ((String) -> Void)?

  /// Slot name to device id, kept for as long as the app runs so an id is never given twice.
  private var ids: [String: String] = [:]
  private var slots: [String: TKSmartCardSlot] = [:]
  private var stateWatches: [String: NSKeyValueObservation] = [:]
  private var namesWatch: NSKeyValueObservation?
  /// The names of the watched slots that hold a valid card.
  private var held: Set<String> = []
  /// The cards with a session begun, by device id.
  private var cards: [String: TKSmartCard] = [:]

  init(manager: TKSmartCardSlotManager) {
    self.manager = manager
  }

  private func id(of name: String) -> String {
    if let id = ids[name] { return id }
    let id = "smartcard:\(ids.count + 1)"
    ids[name] = id
    return id
  }

  private func reader(_ id: String) -> TKSmartCardSlot? {
    guard let name = ids.first(where: { $0.value == id })?.key else { return nil }
    return slots[name] ?? manager.slotNamed(name)
  }

  /// The cards plugged in now. The slot's name is the reader's, which is what the device calls itself.
  func present() -> [[String: Any]] {
    manager.slotNames.compactMap { name in
      guard let slot = slots[name] ?? manager.slotNamed(name), slot.state == .validCard else { return nil }
      return SecurityKeyChannel.device(id(of: name), kind: "smartcard", product: name)
    }
  }

  /// Whether [id] names a slot with a valid card.
  func holds(_ id: String) -> Bool { reader(id)?.state == .validCard }

  /// Starts telling of cards that arrive and leave. Those already in are not told.
  func start() {
    guard namesWatch == nil else { return }
    namesWatch = manager.observe(\.slotNames) { [weak self] _, _ in
      DispatchQueue.main.async { self?.refresh(telling: true) }
    }
    refresh(telling: false)
  }

  func stop() {
    namesWatch?.invalidate()
    namesWatch = nil
    stateWatches.values.forEach { $0.invalidate() }
    stateWatches = [:]
    slots = [:]
    held = []
  }

  /// Brings the watched slots in step with the system's list.
  private func refresh(telling: Bool) {
    guard namesWatch != nil else { return }
    let names = Set(manager.slotNames)
    for name in Array(slots.keys) where !names.contains(name) {
      stateWatches.removeValue(forKey: name)?.invalidate()
      slots[name] = nil
      check(name, telling: true)
    }
    for name in names where slots[name] == nil {
      guard let slot = manager.slotNamed(name) else { continue }
      slots[name] = slot
      stateWatches[name] = slot.observe(\.state) { [weak self] _, _ in
        DispatchQueue.main.async { self?.check(name, telling: true) }
      }
      check(name, telling: telling)
    }
  }

  /// Tells of a card that came into or went from the slot [name] since it was last looked at.
  private func check(_ name: String, telling: Bool) {
    let valid = slots[name]?.state == .validCard
    if valid, !held.contains(name) {
      held.insert(name)
      if telling { arrived?(SecurityKeyChannel.device(id(of: name), kind: "smartcard", product: name)) }
    } else if !valid, held.contains(name) {
      held.remove(name)
      let device = id(of: name)
      cards.removeValue(forKey: device)?.endSession()
      left?(device)
    }
  }

  /// Begins a session with the card of [id]; [done] is called on the main thread.
  func open(_ id: String, done: @escaping (SecurityKeyError?) -> Void) {
    guard let slot = reader(id), slot.state == .validCard, let card = slot.makeSmartCard() else { return done(.removed) }
    cards.removeValue(forKey: id)?.endSession()
    card.beginSession { [weak self] began, error in
      DispatchQueue.main.async {
        guard began, let self else {
          let gone = slot.state != .validCard
          return done(gone ? .removed : .failed(error?.localizedDescription ?? "The smartcard session could not start"))
        }
        self.cards[id] = card
        done(nil)
      }
    }
  }

  func close(_ id: String) {
    cards.removeValue(forKey: id)?.endSession()
  }

  /// Sends one APDU to the card of [id]; the answer ends with the status word. [done] is called
  /// on the main thread.
  func transmit(_ id: String, _ apdu: Data, done: @escaping (Result<Data, SecurityKeyError>) -> Void) {
    guard let card = cards[id] else { return done(.failure(.removed)) }
    card.transmit(apdu) { [weak self] answer, error in
      DispatchQueue.main.async {
        if let answer, answer.count >= 2 { return done(.success(answer)) }
        let gone = self?.holds(id) != true
        done(.failure(gone ? .removed : .failed(error?.localizedDescription ?? "The smartcard gave no answer")))
      }
    }
  }
}

/// The phone's side of `lib/platform/security_keys.dart`: `com.kemlock.app/security_keys` and its
/// events. It finds keys and carries bytes, and knows nothing of what the bytes mean: APDU
/// chaining, CTAP and CBOR are Dart, in `lib/security_key/`. A key is reached over NFC, as an
/// ISO 7816 tag under the system's reader sheet, or plugged into USB-C, as a smartcard.
///
/// Nothing is kept: no storage, no Keychain, no log. A key is named by a counter, and neither a
/// tag's identifier nor its historical bytes leave this file.
///
/// Everything here runs on the main thread: Flutter calls there, the reader session is given the
/// main queue, and CryptoTokenKit's answers are brought back to it.
final class SecurityKeyChannel: NSObject, FlutterStreamHandler, NFCTagReaderSessionDelegate {
  static func register(with registrar: FlutterPluginRegistrar) {
    let handler = SecurityKeyChannel()
    let channel = FlutterMethodChannel(name: "com.kemlock.app/security_keys", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in handler.handle(call, result: result) }
    let events = FlutterEventChannel(name: "com.kemlock.app/security_keys/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(handler)
  }

  /// Shown on the reader sheet when several tags are in the field. Core NFC can talk to one only.
  static let severalTagsMessage = "More than one key was found. Hold only one to the phone."

  /// A device as `SecurityKeyDevice.fromMap` reads it, with its one link, which carries whole APDUs.
  static func device(_ id: String, kind: String, product: String?) -> [String: Any] {
    var device: [String: Any] = ["device": id, "needsPermission": false, "links": [link(id, kind: kind)]]
    if let product { device["product"] = product }
    return device
  }

  static func link(_ id: String, kind: String) -> [String: Any] {
    ["id": id, "kind": kind, "extendedLength": true, "frameSize": 0]
  }

  /// A call that waits for a key's answer. Its result is given once, by whichever comes first of
  /// the answer, the time limit and the key's leaving.
  private final class Call {
    let link: String
    private var result: FlutterResult?

    init(link: String, result: @escaping FlutterResult) {
      self.link = link
      self.result = result
    }

    func take() -> FlutterResult? {
      defer { result = nil }
      return result
    }
  }

  private var sink: FlutterEventSink?
  private var calls: [Call] = []

  private var session: NFCTagReaderSession?
  private var tag: NFCISO7816Tag?
  /// The id of the tag being talked to, which names its device and its link.
  private var nfcDevice: String?
  private var nfcCount = 0
  /// The text Dart last asked for on the reader sheet, put back once a single key is read.
  private var nfcMessage = ""

  /// The `SmartCardSlots`, typed loosely since the class needs iOS 16.
  private var slotsMade: AnyObject?

  @available(iOS 16.0, *)
  private var smartcards: SmartCardSlots? {
    if let made = slotsMade as? SmartCardSlots { return made }
    guard let manager = TKSmartCardSlotManager.default else { return nil }
    let made = SmartCardSlots(manager: manager)
    made.arrived = { [weak self] device in
      self?.emit(device.merging(["event": "arrived"]) { first, _ in first })
    }
    made.left = { [weak self] id in
      self?.failCalls(on: id, with: .removed)
      self?.emit(["event": "left", "device": id])
    }
    slotsMade = made
    return made
  }

  // MARK: The method channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let link = arguments["link"] as? String ?? ""
    switch call.method {
    case "capabilities":
      result(capabilities())
    case "present":
      if #available(iOS 16.0, *) { result(smartcards?.present() ?? []) } else { result([[String: Any]]()) }
    case "requestPermission":
      // iOS asks no question about a device: its links are known from the start
      result(links(of: arguments["device"] as? String ?? ""))
    case "beginNfc":
      answer(result, beginNfc(arguments["message"] as? String ?? ""))
    case "setNfcMessage":
      if let message = arguments["message"] as? String {
        nfcMessage = message
        session?.alertMessage = message
      }
      result(nil)
    case "endNfc":
      endNfc(error: arguments["error"] as? String)
      result(nil)
    case "open":
      open(link, result: result)
    case "close":
      if #available(iOS 16.0, *), link.hasPrefix("smartcard:") { smartcards?.close(link) }
      result(nil)
    case "transceive":
      guard let apdu = (arguments["data"] as? FlutterStandardTypedData)?.data else {
        return answer(result, .failure(.failed("No APDU")))
      }
      transceive(link, apdu, timeoutMs: arguments["timeoutMs"] as? Int ?? 5000, result: result)
    case "write", "read":
      // Raw frames are for Android's USB links
      answer(result, .failure(.unavailable))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func answer(_ result: FlutterResult, _ outcome: Result<Any?, SecurityKeyError>) {
    switch outcome {
    case .success(let value): result(value)
    case .failure(let error): result(FlutterError(code: error.code, message: error.message, details: nil))
    }
  }

  private func capabilities() -> [String: Any] {
    // False on an iPad and in the simulator. An iPhone's NFC cannot be turned off.
    let nfc = NFCTagReaderSession.readingAvailable
    var smartcards = false
    if #available(iOS 16.0, *) { smartcards = TKSmartCardSlotManager.default != nil }
    return ["nfc": nfc, "nfcOn": nfc, "usb": false, "smartcards": smartcards, "readsOnRequest": true]
  }

  private func links(of device: String) -> [[String: Any]] {
    if device == nfcDevice { return [Self.link(device, kind: "nfc")] }
    if #available(iOS 16.0, *), device.hasPrefix("smartcard:"), smartcards?.holds(device) == true {
      return [Self.link(device, kind: "smartcard")]
    }
    return []
  }

  private func open(_ link: String, result: @escaping FlutterResult) {
    if link.hasPrefix("smartcard:"), #available(iOS 16.0, *), let smartcards {
      smartcards.open(link) { error in
        if let error { self.answer(result, .failure(error)) } else { self.answer(result, .success(nil)) }
      }
    } else if link == nfcDevice, tag != nil {
      // The reader session connected the tag before telling of it
      result(nil)
    } else {
      answer(result, .failure(.removed))
    }
  }

  private func transceive(_ link: String, _ apdu: Data, timeoutMs: Int, result: @escaping FlutterResult) {
    if link.hasPrefix("smartcard:"), #available(iOS 16.0, *), let smartcards {
      let call = track(link, result, timeoutMs: timeoutMs)
      smartcards.transmit(link, apdu) { outcome in
        self.finish(call, outcome.map { answer -> Any? in FlutterStandardTypedData(bytes: answer) })
      }
      return
    }
    guard link == nfcDevice, let tag else { return answer(result, .failure(.removed)) }
    if let name = SecurityKeyApdu.selectedName(apdu), !SecurityKeyApdu.isDeclared(name, in: SecurityKeyApdu.declared) {
      return answer(result, .failure(.notDeclared))
    }
    guard let command = NFCISO7816APDU(data: apdu) else { return answer(result, .failure(.failed("Not an APDU"))) }
    let call = track(link, result, timeoutMs: timeoutMs)
    tag.sendCommand(apdu: command, completionHandler: { (data: Data, sw1: UInt8, sw2: UInt8, error: Error?) in
      DispatchQueue.main.async {
        if let error { return self.finish(call, .failure(SecurityKeyError.from(nfc: error))) }
        self.finish(call, .success(FlutterStandardTypedData(bytes: data + Data([sw1, sw2]))))
      }
    })
  }

  // MARK: Calls that wait

  /// Keeps [result] until the key answers, and answers `timeout` itself after [timeoutMs]: Core
  /// NFC has no time limit to set on a command. An answer that comes later is dropped.
  private func track(_ link: String, _ result: @escaping FlutterResult, timeoutMs: Int) -> Call {
    let call = Call(link: link, result: result)
    calls.append(call)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(timeoutMs, 1))) { [weak self] in
      self?.finish(call, .failure(.timeout))
    }
    return call
  }

  private func finish(_ call: Call, _ outcome: Result<Any?, SecurityKeyError>) {
    guard let result = call.take() else { return }
    calls.removeAll { $0 === call }
    answer(result, outcome)
  }

  private func failCalls(on link: String, with error: SecurityKeyError) {
    for call in calls where call.link == link { finish(call, .failure(error)) }
  }

  // MARK: The event channel

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    if #available(iOS 16.0, *) { smartcards?.start() }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    if #available(iOS 16.0, *) { smartcards?.stop() }
    endNfc(error: nil)
    return nil
  }

  private func emit(_ event: [String: Any]) {
    sink?(event)
  }

  // MARK: NFC

  private func beginNfc(_ message: String) -> Result<Any?, SecurityKeyError> {
    guard NFCTagReaderSession.readingAvailable else { return .failure(.unavailable) }
    nfcMessage = message
    if let session {
      session.alertMessage = message
      return .success(nil)
    }
    guard let started = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: DispatchQueue.main) else {
      return .failure(.unavailable)
    }
    started.alertMessage = message
    session = started
    started.begin()
    return .success(nil)
  }

  /// Ends the reader session, with a tick or, with [error], with that text and a cross. The
  /// session is forgotten at once, so what iOS says of its end afterwards is not told again.
  private func endNfc(error: String?) {
    guard let session else { return }
    self.session = nil
    dropTag(failing: .removed)
    emit(["event": "sessionEnded"])
    if let error, !error.isEmpty { session.invalidate(errorMessage: error) } else { session.invalidate() }
  }

  /// Forgets the tag, fails the calls that wait on it and tells Dart it left.
  private func dropTag(failing error: SecurityKeyError) {
    guard let device = nfcDevice else { return }
    tag = nil
    nfcDevice = nil
    failCalls(on: device, with: error)
    emit(["event": "left", "device": device])
  }

  func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

  func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    // A session the app ended itself was told of in endNfc
    guard session === self.session else { return }
    self.session = nil
    let reason = SecurityKeyError.from(nfc: error)
    dropTag(failing: reason == .cancelled ? .cancelled : .removed)
    var event: [String: Any] = ["event": "sessionEnded", "code": reason.code]
    if let message = reason.message { event["message"] = message }
    emit(event)
  }

  func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard session === self.session else { return }
    // Only after a restart can a tag be found while one is held: the earlier one is gone
    dropTag(failing: .removed)
    guard tags.count == 1 else {
      session.alertMessage = Self.severalTagsMessage
      return session.restartPolling()
    }
    guard case .iso7816(let card) = tags[0] else { return session.restartPolling() }
    session.connect(to: tags[0]) { [weak self] error in
      DispatchQueue.main.async {
        guard let self, session === self.session else { return }
        guard error == nil else { return session.restartPolling() }
        if session.alertMessage == Self.severalTagsMessage { session.alertMessage = self.nfcMessage }
        self.nfcCount += 1
        let id = "nfc:\(self.nfcCount)"
        self.tag = card
        self.nfcDevice = id
        self.emit(Self.device(id, kind: "nfc", product: nil).merging(["event": "arrived"]) { first, _ in first })
      }
    }
  }
}
