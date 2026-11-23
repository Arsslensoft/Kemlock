import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/security_key/openpgp_card/card_data.dart';

void main() {
  test("iPhone is told of the OpenPGP card application's identifier", () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final list = RegExp(
      r'<key>com\.apple\.developer\.nfc\.readersession\.iso7816\.select-identifiers</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist);
    expect(list, isNotNull, reason: 'the list of identifiers iPhone lets the app select');

    final identifiers = [for (final match in RegExp(r'<string>([0-9A-Fa-f]+)</string>').allMatches(list![1]!)) match[1]!.toUpperCase()];
    expect(identifiers, contains(cardHex(openPgpAid)));
    expect(cardHex(openPgpAid), 'D27600012401');
  });
}
