import CommonCrypto
import Foundation

/// One-time codes as lib/features/accounts/otp.dart makes them, from the
/// secret bytes the app decoded: RFC 6238 TOTP and Steam Guard. CommonCrypto
/// rather than CryptoKit, which has no SHA-224.
enum OneTimeCode {
  private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")

  /// The code for the window containing [nowSec] (Unix time in whole seconds), or nil when the account can't make one.
  static func code(for account: AutofillAccount, at nowSec: Int64) -> String? {
    guard account.period > 0 else { return nil }
    let counter = floorDiv(nowSec, Int64(account.period))
    switch account.kind {
    case .steam:
      guard let mac = hmac(algorithm: "SHA1", key: account.key, counter: counter) else { return nil }
      var value = truncate(mac)
      var code = ""
      for _ in 0..<5 {
        code.append(steamAlphabet[Int(value % UInt32(steamAlphabet.count))])
        value /= UInt32(steamAlphabet.count)
      }
      return code
    case .totp:
      guard (1...10).contains(account.digits), let mac = hmac(algorithm: account.algorithm, key: account.key, counter: counter) else { return nil }
      let value = UInt64(truncate(mac))
      // Any value fits in 10 digits; 10 pads it with zeros
      let code = account.digits >= 10 ? value : value % pow10(account.digits)
      let text = String(code)
      return String(repeating: "0", count: max(0, account.digits - text.count)) + text
    }
  }

  /// Seconds left before the code of a [period]-second window changes, at [nowSec]: 1 to [period].
  static func secondsRemaining(period: Int, at nowSec: Int64) -> Int {
    guard period > 0 else { return 0 }
    return period - Int(nowSec - floorDiv(nowSec, Int64(period)) * Int64(period))
  }

  /// HMAC of [counter] as 8 big-endian bytes, or nil for an algorithm the app never hands over.
  static func hmac(algorithm: String, key: Data, counter: Int64) -> [UInt8]? {
    let (alg, length): (CCHmacAlgorithm, Int32)
    switch algorithm {
    case "SHA1": (alg, length) = (CCHmacAlgorithm(kCCHmacAlgSHA1), CC_SHA1_DIGEST_LENGTH)
    case "SHA224": (alg, length) = (CCHmacAlgorithm(kCCHmacAlgSHA224), CC_SHA224_DIGEST_LENGTH)
    case "SHA256": (alg, length) = (CCHmacAlgorithm(kCCHmacAlgSHA256), CC_SHA256_DIGEST_LENGTH)
    case "SHA384": (alg, length) = (CCHmacAlgorithm(kCCHmacAlgSHA384), CC_SHA384_DIGEST_LENGTH)
    case "SHA512": (alg, length) = (CCHmacAlgorithm(kCCHmacAlgSHA512), CC_SHA512_DIGEST_LENGTH)
    default: return nil
    }
    var message = [UInt8](repeating: 0, count: 8)
    var rest = UInt64(bitPattern: counter)
    for i in (0..<8).reversed() {
      message[i] = UInt8(rest & 0xff)
      rest >>= 8
    }
    var mac = [UInt8](repeating: 0, count: Int(length))
    key.withUnsafeBytes { keyBytes in
      CCHmac(alg, keyBytes.baseAddress, key.count, message, message.count, &mac)
    }
    return mac
  }

  /// RFC 4226's dynamic truncation: 31 bits from the offset the last byte gives.
  private static func truncate(_ mac: [UInt8]) -> UInt32 {
    let offset = Int(mac[mac.count - 1] & 0xf)
    return UInt32(mac[offset] & 0x7f) << 24 | UInt32(mac[offset + 1]) << 16 | UInt32(mac[offset + 2]) << 8 | UInt32(mac[offset + 3])
  }

  private static func pow10(_ exponent: Int) -> UInt64 {
    (0..<exponent).reduce(1) { value, _ in value * 10 }
  }

  private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let quotient = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
  }
}
