import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/piv/piv_data.dart';

void main() {
  test('iPhone is told of the PIV application, so it may be selected over NFC', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final list = RegExp(
      r'<key>com\.apple\.developer\.nfc\.readersession\.iso7816\.select-identifiers</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist);
    expect(list, isNotNull);
    final identifiers = [for (final match in RegExp('<string>([0-9A-Fa-f]+)</string>').allMatches(list![1]!)) match[1]!.toUpperCase()];

    final piv = [for (final byte in pivAid) byte.toRadixString(16).padLeft(2, '0')].join().toUpperCase();
    expect(piv, 'A000000308');
    expect(identifiers, contains(piv));
  });
}
