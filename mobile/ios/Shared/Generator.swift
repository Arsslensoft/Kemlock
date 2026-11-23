import Foundation

// Random passwords, made as lib/features/generator/generator.dart makes them, so that equal
// choices, rules and random bytes give an equal password (openspec: password-generator;
// add-passwords, design decision 5), and a site's password rules read as
// lib/features/generator/password_rules.dart reads them. The shared cases are
// test/fixtures/generator/cases.json. Passphrases are the app's alone.

/// The symbols the generator uses by default.
let generatorSymbols = "!#%&-_?"

/// Characters people mistake for one another, left out when asked.
let lookAlikes = "0O1lI"

let minPasswordLength = 8
let maxPasswordLength = 64
let defaultPasswordLength = 20

/// Where random bytes come from: the phone's secure source, or a fixed stream in the tests.
protocol ByteSource: AnyObject {
  /// A byte, 0 to 255.
  func nextByte() throws -> Int
}

/// The phone's cryptographically secure random source.
final class SecureByteSource: ByteSource {
  func nextByte() -> Int { Int(PasskeyBytes.randomBytes(1)[0]) }
}

/// A fixed stream of bytes, for the shared test cases. Running out is an error.
final class FixedByteSource: ByteSource {
  struct OutOfBytes: Error {}

  private let bytes: [UInt8]
  private var next = 0

  init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  func nextByte() throws -> Int {
    guard next < bytes.count else { throw OutOfBytes() }
    next += 1
    return Int(bytes[next - 1])
  }
}

/// A number below [n] with every value as likely: bytes that would favour the low values are
/// drawn again. Up to 256 values from one byte, more from two, most significant first.
func pickBelow(_ source: ByteSource, _ n: Int) throws -> Int {
  precondition(n > 0, "n must be positive: \(n)")
  if n <= 256 {
    let limit = 256 - 256 % n
    while true {
      let b = try source.nextByte()
      if b < limit { return b % n }
    }
  }
  let limit = 65536 - 65536 % n
  while true {
    let high = try source.nextByte()
    let low = try source.nextByte()
    let v = (high << 8) | low
    if v < limit { return v % n }
  }
}

/// What a random password is made of; AutoFill makes them with the defaults.
struct PasswordChoices: Equatable {
  var length = defaultPasswordLength
  var capitals = true
  var digits = true
  var symbols = true
  var avoidLookAlikes = true
}

/// The sets one character of each must be in the password, the alphabet the rest is drawn from,
/// its length and the longest run allowed.
struct PasswordPlan: Equatable {
  let required: [String]
  let alphabet: String
  let length: Int
  let maxConsecutive: Int?
}

/// [scalars] as a string.
private func scalarText<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
  var out = ""
  out.unicodeScalars.append(contentsOf: scalars)
  return out
}

private func withoutLookAlikes(_ chars: String, _ avoid: Bool) -> String {
  avoid ? scalarText(chars.unicodeScalars.filter { !lookAlikes.unicodeScalars.contains($0) }) : chars
}

private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int { min(max(value, lower), upper) }

/// The plan for [choices] under [rules]: each chosen set keeps what the site allows, and every
/// set the site requires that no kept set lies within is added. Rules that can't be met are left
/// out, and [choices] made alone.
func passwordPlan(_ choices: PasswordChoices, _ rules: PasswordRules? = nil) -> PasswordPlan {
  let avoid = choices.avoidLookAlikes
  var chosen = [withoutLookAlikes(lowerChars, avoid)]
  if choices.capitals { chosen.append(withoutLookAlikes(upperChars, avoid)) }
  if choices.digits { chosen.append(withoutLookAlikes(digitChars, avoid)) }
  if choices.symbols { chosen.append(generatorSymbols) }
  let plain = PasswordPlan(
    required: chosen, alphabet: unionOf(chosen), length: clamp(choices.length, minPasswordLength, maxPasswordLength), maxConsecutive: nil)
  guard let rules, !rules.isEmpty else { return plain }

  // What the site takes: what it allows and requires, or any printable character when it says neither
  let allowed = rules.allowed != nil || !rules.required.isEmpty ? unionOf(rules.required + [rules.allowed].compactMap { $0 }) : asciiPrintable
  let kept = chosen.map { intersect($0, allowed) }.filter { !$0.isEmpty }
  let ours = unionOf(chosen)
  var siteRequired: [String] = []
  for set in rules.required {
    // From the site's set, the characters this generator uses when any, else the set without space, else all of it
    let preferred = withoutLookAlikes(intersect(set, ours), avoid)
    let fallback = withoutLookAlikes(scalarText(set.unicodeScalars.filter { $0 != " " }), avoid)
    let pick = !preferred.isEmpty ? preferred : !fallback.isEmpty ? fallback : set
    if !kept.contains(where: { intersect($0, set).unicodeScalars.count == $0.unicodeScalars.count }) { siteRequired.append(pick) }
  }
  let required = kept + siteRequired
  let least = max(rules.minLength ?? 1, required.count)
  let top = rules.maxLength ?? maxPasswordLength
  let length = clamp(choices.length, least, max(least, top))
  if required.isEmpty || required.contains(where: \.isEmpty) || (rules.maxLength.map { $0 < least } ?? false) || length > top {
    return plain
  }
  return PasswordPlan(required: required, alphabet: unionOf(required), length: length, maxConsecutive: rules.maxConsecutive)
}

/// A random password: one character from each required set first, then characters from the
/// whole alphabet to the length, then shuffled (Fisher–Yates), every draw from [source] by
/// [pickBelow]. A character that would make a run longer than the rules allow is drawn again.
func generatePassword(_ source: ByteSource, _ choices: PasswordChoices = PasswordChoices(), rules: PasswordRules? = nil) throws -> String {
  let plan = passwordPlan(choices, rules)
  let alphabet = Array(plan.alphabet.unicodeScalars)
  var chars: [Unicode.Scalar] = []
  for set in plan.required {
    let scalars = Array(set.unicodeScalars)
    chars.append(scalars[try pickBelow(source, scalars.count)])
  }
  while chars.count < plan.length { chars.append(alphabet[try pickBelow(source, alphabet.count)]) }
  for i in stride(from: chars.count - 1, to: 0, by: -1) {
    chars.swapAt(i, try pickBelow(source, i + 1))
  }
  if let most = plan.maxConsecutive, most > 0, alphabet.count > 1, chars.count > 1 {
    var run = 1
    for i in 1..<chars.count {
      run = chars[i] == chars[i - 1] ? run + 1 : 1
      while run > most {
        chars[i] = alphabet[try pickBelow(source, alphabet.count)]
        run = chars[i] == chars[i - 1] ? run : 1
      }
    }
  }
  return scalarText(chars)
}

// ─── Password rules ────────────────────────────────────────────────────────

/// Characters of each named class, in the order the generator draws from them.
let lowerChars = "abcdefghijklmnopqrstuvwxyz"
let upperChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
let digitChars = "0123456789"

/// Apple's `special`: ``-~!@#$%^&*_+=`|(){}[:;"'<>,.?]`` and space.
let specialChars = "-~!@#$%^&*_+=`|(){}[:;\"'<>,.?] "

/// Every printable ASCII character, space to tilde.
let asciiPrintable = scalarText((UInt8(0x20)...UInt8(0x7e)).map { Unicode.Scalar($0) })

/// A site's rules, in the language of Apple's `passwordrules` attribute and
/// password-manager-resources: `minlength: 8; maxlength: 16; required: lower;
/// required: upper, digit; allowed: [-_]; max-consecutive: 2`. A nil field says nothing about it.
struct PasswordRules: Equatable {
  var minLength: Int?
  var maxLength: Int?
  /// Each a set of characters at least one of which the password must hold.
  var required: [String] = []
  /// The characters the password may hold, besides the required ones; nil when the rules name none.
  var allowed: String?
  var maxConsecutive: Int?

  var isEmpty: Bool { minLength == nil && maxLength == nil && required.isEmpty && allowed == nil && maxConsecutive == nil }

  /// Reads [text]; a rule it doesn't know is skipped, as browsers do.
  static func parse(_ text: String) -> PasswordRules {
    var rules = PasswordRules()
    for rule in splitRules(Array(text.unicodeScalars)) {
      guard let colon = rule.firstIndex(of: ":") else { continue }
      let name = scalarText(rule[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = scalarText(rule[(colon + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      switch name {
      case "minlength": rules.minLength = Int(value)
      case "maxlength": rules.maxLength = Int(value)
      case "max-consecutive": rules.maxConsecutive = Int(value)
      case "required":
        let chars = classes(Array(value.unicodeScalars))
        if !chars.isEmpty { rules.required.append(chars) }
      case "allowed": rules.allowed = unionOf([rules.allowed, classes(Array(value.unicodeScalars))].compactMap { $0 })
      default: break
      }
    }
    return rules
  }

  /// Splits at the semicolons outside brackets: a custom class may hold one.
  private static func splitRules(_ text: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
    var rules: [[Unicode.Scalar]] = []
    var start = 0
    var inClass = false
    var i = 0
    while i < text.count {
      let c = text[i]
      if c == "[" && !inClass {
        inClass = true
        // A ] right after the opening bracket is a character of the class
        if i + 1 < text.count && text[i + 1] == "]" { i += 1 }
      } else if c == "]" && inClass {
        inClass = false
      } else if c == ";" && !inClass {
        rules.append(Array(text[start..<i]))
        start = i + 1
      }
      i += 1
    }
    rules.append(Array(text[start...]))
    return rules.filter { !scalarText($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  /// The characters of a comma-separated list of classes and `[...]` sets.
  private static func classes(_ value: [Unicode.Scalar]) -> String {
    var parts: [String] = []
    var i = 0
    while i < value.count {
      let c = value[i]
      // Any space separates, as a comma does: a site's own rules may hold a tab
      if c == "," || c.properties.isWhitespace {
        i += 1
      } else if c == "[" {
        // A custom set: everything up to the closing bracket, a ] first being one of its characters
        var end = i + 2 <= value.count ? (value[(i + 2)...].firstIndex(of: "]") ?? -1) : -1
        if end < 0 { end = value.count }
        parts.append(scalarText(value[min(i + 1, end)..<end]))
        i = end + 1
      } else {
        let end = value[i...].firstIndex { $0 == "," || $0 == "[" || $0.properties.isWhitespace } ?? value.count
        switch scalarText(value[i..<end]).lowercased() {
        case "lower": parts.append(lowerChars)
        case "upper": parts.append(upperChars)
        case "digit": parts.append(digitChars)
        case "special": parts.append(specialChars)
        case "ascii-printable", "unicode": parts.append(asciiPrintable)
        default: break
        }
        i = end
      }
    }
    return unionOf(parts)
  }
}

/// [sets] joined, each character once, in the order they first appear.
func unionOf(_ sets: [String]) -> String {
  var seen = Set<Unicode.Scalar>()
  return scalarText(sets.flatMap(\.unicodeScalars).filter { seen.insert($0).inserted })
}

/// [a]'s characters that are also in [b], in [a]'s order.
func intersect(_ a: String, _ b: String) -> String {
  let inB = Set(b.unicodeScalars)
  return scalarText(a.unicodeScalars.filter { inB.contains($0) })
}
