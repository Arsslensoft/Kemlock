import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kemlock/crypto/pbkdf2.dart';

import 'fake_security_keys.dart';

/// One account on a [FakeOathKey], with the secret a real key never gives back.
class FakeOathAccount {
  FakeOathAccount(
    this.name,
    List<int> secret, {
    this.hotp = false,
    this.algorithm = 'SHA1',
    this.digits = 6,
    this.touch = false,
    this.counter = 0,
  }) : secret = Uint8List.fromList(secret);

  /// The name on the key, `[period/]issuer:label`.
  final String name;
  Uint8List secret;
  final bool hotp;

  /// `SHA1`, `SHA256` or `SHA512`.
  final String algorithm;
  final int digits;
  final bool touch;

  /// The counter the next code of a counter-based account is made from.
  int counter;

  int get _typeByte => (hotp ? 0x10 : 0x20) | const {'SHA1': 1, 'SHA256': 2, 'SHA512': 3}[algorithm]!;

  Hash get _hash => const {'SHA1': sha1, 'SHA256': sha256, 'SHA512': sha512}[algorithm]!;
}

/// Yubico's OATH application in software, written from the protocol page
/// (https://developers.yubico.com/OATH/YKOATH_Protocol.html) and not from
/// the app's own code: a [FakeApplet] for a [FakeKey].
///
/// ```dart
/// final oath = FakeOathKey(accounts: [FakeOathAccount('Example:alice@example.org', secret)]);
/// phone.arrive(FakeKey(applets: [oath]).device(kinds: {SecurityKeyLinkKind.nfc}));
/// oath.password = 'correct horse';     // the application asks for it from the next SELECT
/// oath.touchGiven = false;             // nobody touches the key
/// oath.corruptPuts = true;             // a PUT stores a damaged secret
/// oath.wrongProof = true;              // VALIDATE is accepted, the key's own proof is wrong
/// expect(oath.received, [0xa1, 0xa4, 0xa4]);
/// ```
class FakeOathKey extends FakeApplet {
  FakeOathKey({List<FakeOathAccount>? accounts, String? password, this.version = const [5, 4, 3], List<int>? id, this._capacity})
    : accounts = accounts ?? [],
      id = Uint8List.fromList(id ?? const [1, 2, 3, 4, 5, 6, 7, 8]) {
    this.password = password;
  }

  final List<FakeOathAccount> accounts;

  /// The firmware version, as the three bytes SELECT gives.
  List<int> version;

  /// The application's id: the salt of its password. A reset gives a new one.
  Uint8List id;

  final int? _capacity;

  /// How many accounts fit: 32, and 64 from firmware 5.7, unless the test says.
  int get capacity => _capacity ?? (_atLeast(5, 7, 0) ? 64 : 32);

  /// What proves the password, or null without one.
  Uint8List? accessKey;

  /// Sets or removes the password as another tool would.
  set password(String? password) => accessKey = password == null ? null : pbkdf2Sha1(utf8.encode(password), id, 1000, 16);

  /// Whether the key is touched when an account waits for it.
  bool touchGiven = true;

  /// A PUT stores a secret with one byte changed.
  bool corruptPuts = false;

  /// The key accepts the password and answers VALIDATE with a wrong proof.
  bool wrongProof = false;

  /// The most bytes of an answer handed out at once.
  int chunk = 255;

  /// The instruction of every command received since it was last cleared.
  final List<int> received = [];

  bool _unlocked = false;
  int _challenges = 0;
  Uint8List _challenge = Uint8List(8);
  Uint8List _rest = Uint8List(0);

  @override
  List<int> get aid => const [0xa0, 0x00, 0x00, 0x05, 0x27, 0x21, 0x01];

  bool _atLeast(int major, int minor, int patch) {
    final have = version[0] << 16 | version[1] << 8 | version[2];
    return have >= (major << 16 | minor << 8 | patch);
  }

  @override
  List<int> get selectAnswer {
    _unlocked = false;
    _rest = Uint8List(0);
    _challenges++;
    _challenge = Uint8List.fromList([0xc0, 0xff, 0xee, 0, 0, 0, _challenges >> 8 & 0xff, _challenges & 0xff]);
    return [
      0x79, 3, ...version, //
      0x71, id.length, ...id,
      if (accessKey != null) ...[0x74, 8, ..._challenge, 0x7b, 1, 0x01],
    ];
  }

  FakeOathAccount? find(String name) => accounts.where((account) => account.name == name).firstOrNull;

  /// The values of [data] by tag, or null when it does not parse.
  static List<(int, Uint8List)>? _tlvs(Uint8List data) {
    final out = <(int, Uint8List)>[];
    var offset = 0;
    while (offset < data.length) {
      if (offset + 2 > data.length) return null;
      final tag = data[offset];
      // The property of PUT is a tag and one byte.
      if (tag == 0x78) {
        out.add((tag, Uint8List.sublistView(data, offset + 1, offset + 2)));
        offset += 2;
        continue;
      }
      final length = data[offset + 1];
      if (length >= 0x80 || offset + 2 + length > data.length) return null;
      out.add((tag, Uint8List.sublistView(data, offset + 2, offset + 2 + length)));
      offset += 2 + length;
    }
    return out;
  }

  static List<int> _tlv(int tag, List<int> value) => [tag, value.length, ...value];

  static Uint8List? _value(List<(int, Uint8List)> values, int tag) {
    for (final (found, value) in values) {
      if (found == tag) return value;
    }
    return null;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Uint8List _counterBytes(int counter) {
    final bytes = Uint8List(8);
    for (var i = 7, rest = counter; i >= 0; i--, rest >>= 8) {
      bytes[i] = rest & 0xff;
    }
    return bytes;
  }

  (List<int>, int) _hand(List<int> answer) {
    if (answer.length <= chunk) {
      _rest = Uint8List(0);
      return (answer, 0x9000);
    }
    _rest = Uint8List.fromList(answer.sublist(chunk));
    return (answer.sublist(0, chunk), 0x6100 | (_rest.length > 0xff ? 0xff : _rest.length));
  }

  /// The answer of [account] over [challenge]: the digits, then the HMAC,
  /// whole or truncated to four bytes.
  List<int> _response(FakeOathAccount account, List<int> challenge, {required bool truncated}) {
    final mac = Hmac(account._hash, account.secret).convert(challenge).bytes;
    if (!truncated) return _tlv(0x75, [account.digits, ...mac]);
    final offset = mac.last & 0x0f;
    return _tlv(0x76, [account.digits, mac[offset] & 0x7f, mac[offset + 1], mac[offset + 2], mac[offset + 3]]);
  }

  @override
  (List<int>, int) command(int cla, int ins, int p1, int p2, Uint8List data) {
    received.add(ins);
    if (cla != 0) return (const [], 0x6e00);
    if (ins == 0xa5) return _hand(_rest);
    if (ins == 0x04) {
      if (p1 != 0xde || p2 != 0xad) return (const [], 0x6a80);
      accounts.clear();
      accessKey = null;
      _unlocked = false;
      id = Uint8List.fromList([for (final byte in id) (byte * 7 + 0x5b) & 0xff]);
      return (const [], 0x9000);
    }
    final values = _tlvs(data);
    if (values == null) return (const [], 0x6a80);
    if (ins == 0xa3) return _validate(values);
    if (accessKey != null && !_unlocked) return (const [], 0x6982);
    return switch (ins) {
      0x01 => _put(values),
      0x02 => _delete(values),
      0x03 => _setCode(values),
      0xa1 => _hand([
        for (final account in accounts) ..._tlv(0x72, [account._typeByte, ...utf8.encode(account.name)]),
      ]),
      0xa2 => _calculate(values, truncated: p2 == 0x01),
      0xa4 => _calculateAll(values, truncated: p2 == 0x01),
      _ => (const [], 0x6d00),
    };
  }

  (List<int>, int) _validate(List<(int, Uint8List)> values) {
    final key = accessKey;
    final response = _value(values, 0x75);
    final challenge = _value(values, 0x74);
    if (key == null) return (const [], 0x6984);
    if (response == null || challenge == null) return (const [], 0x6a80);
    if (!_same(response, Hmac(sha1, key).convert(_challenge).bytes)) return (const [], 0x6a80);
    _unlocked = true;
    final proof = Hmac(sha1, key).convert(challenge).bytes;
    return (_tlv(0x75, wrongProof ? [for (final byte in proof) byte ^ 0x55] : proof), 0x9000);
  }

  (List<int>, int) _put(List<(int, Uint8List)> values) {
    final name = _value(values, 0x71);
    final key = _value(values, 0x73);
    if (name == null || key == null || name.isEmpty || name.length > 64 || key.length < 2 + 14) return (const [], 0x6a80);
    final hotp = key[0] & 0xf0 == 0x10;
    if (!hotp && key[0] & 0xf0 != 0x20) return (const [], 0x6a80);
    final algorithm = const {1: 'SHA1', 2: 'SHA256', 3: 'SHA512'}[key[0] & 0x0f];
    if (algorithm == null) return (const [], 0x6a80);
    if (algorithm == 'SHA512' && !_atLeast(4, 3, 1)) return (const [], 0x6a80);
    final property = _value(values, 0x78);
    final touch = property != null && property[0] & 0x02 != 0;
    if (touch && !_atLeast(4, 2, 4)) return (const [], 0x6a80);
    final imf = _value(values, 0x7a);
    if (imf != null && imf.length != 4) return (const [], 0x6a80);
    final text = utf8.decode(name, allowMalformed: true);
    final held = find(text);
    if (held == null && accounts.length >= capacity) return (const [], 0x6a84);
    final secret = Uint8List.fromList(key.sublist(2));
    if (corruptPuts) secret[0] ^= 0xff;
    final account = FakeOathAccount(
      text,
      secret,
      hotp: hotp,
      algorithm: algorithm,
      digits: key[1],
      touch: touch,
      counter: imf == null ? 0 : imf[0] << 24 | imf[1] << 16 | imf[2] << 8 | imf[3],
    );
    if (held == null) {
      accounts.add(account);
    } else {
      accounts[accounts.indexOf(held)] = account;
    }
    return (const [], 0x9000);
  }

  (List<int>, int) _delete(List<(int, Uint8List)> values) {
    final name = _value(values, 0x71);
    if (name == null) return (const [], 0x6a80);
    final held = find(utf8.decode(name, allowMalformed: true));
    if (held == null) return (const [], 0x6984);
    accounts.remove(held);
    return (const [], 0x9000);
  }

  (List<int>, int) _setCode(List<(int, Uint8List)> values) {
    final key = _value(values, 0x73);
    if (key == null) return (const [], 0x6a80);
    if (key.isEmpty) {
      accessKey = null;
      return (const [], 0x9000);
    }
    final challenge = _value(values, 0x74);
    final response = _value(values, 0x75);
    if (key.length != 17 || challenge == null || response == null) return (const [], 0x6a80);
    final fresh = Uint8List.fromList(key.sublist(1));
    if (!_same(response, Hmac(sha1, fresh).convert(challenge).bytes)) return (const [], 0x6984);
    accessKey = fresh;
    return (const [], 0x9000);
  }

  (List<int>, int) _calculate(List<(int, Uint8List)> values, {required bool truncated}) {
    final name = _value(values, 0x71);
    final challenge = _value(values, 0x74);
    if (name == null || challenge == null) return (const [], 0x6a80);
    final account = find(utf8.decode(name, allowMalformed: true));
    if (account == null) return (const [], 0x6984);
    // Nobody touched the key before it gave up waiting.
    if (account.touch && !touchGiven) return (const [], 0x6982);
    if (account.hotp) return (_response(account, _counterBytes(account.counter++), truncated: truncated), 0x9000);
    if (challenge.isEmpty) return (const [], 0x6a80);
    return (_response(account, challenge, truncated: truncated), 0x9000);
  }

  (List<int>, int) _calculateAll(List<(int, Uint8List)> values, {required bool truncated}) {
    final challenge = _value(values, 0x74);
    if (challenge == null || challenge.isEmpty) return (const [], 0x6a80);
    return _hand([
      for (final account in accounts) ...[
        ..._tlv(0x71, utf8.encode(account.name)),
        if (account.hotp)
          ..._tlv(0x77, [account.digits])
        else if (account.touch)
          ..._tlv(0x7c, [account.digits])
        else
          ..._response(account, challenge, truncated: truncated),
      ],
    ]);
  }
}
