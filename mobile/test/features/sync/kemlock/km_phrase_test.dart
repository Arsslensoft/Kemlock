import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/crypto/account/encoding.dart';
import 'package:kemlock/features/generator/word_list.dart';
import 'package:kemlock/features/sync/kemlock/km_phrase.dart';

List<String> _words() => parseWordList(File('assets/data/eff_large_wordlist.txt').readAsStringSync());

/// 1,600 bytes that all hold [value], standing for a one-time `kx1` public key.
Uint8List _key(int value) => Uint8List.fromList(List.filled(1600, value));

void main() {
  group('the word list', () {
    test('is EFF\'s large list: its words, one a line, hash to the server\'s file', () {
      // The app bundles the list as EFF serves it, with dice digits; the server's file holds the words only.
      final words = _words();
      expect(words, hasLength(effWordCount));
      expect(words.first, 'abacus');
      expect(
        sha256.convert('${words.join('\n')}\n'.codeUnits).toString(),
        '6d557f0693958fb5e650b68b5bee585eb82cf4da32965505c789e924743bc522',
      );
    });
  });

  group('approvalPhrase', () {
    // Derived by hand from crypto.md's definition (SHA-256 over the label and the key, the first 65 bits as
    // five 13-bit groups, each mod 7776), with a script outside the app, not from the app's own code.
    test('a key of all 1s: 6063, 5781, 4842, 5533 and 7851, which wraps to word 75', () {
      expect(approvalPhrase(_key(1), _words()), 'slurp series primary ruined afraid');
    });

    test('a key of all 7s: 4450, 4474, 7039, 4300 and 123', () {
      expect(approvalPhrase(_key(7), _words()), 'panama paradox undamaged outlook almanac');
    });

    test('a key counting 0 to 255 over and over', () {
      final key = Uint8List.fromList([for (var i = 0; i < 1600; i++) i % 256]);
      expect(approvalPhrase(key, _words()), 'wrought trusting reach protector flaky');
    });

    test('a group from 7776 up wraps with mod 7776, so the first words come up twice as often', () {
      // The all-1s key's fifth group is 7851 and 7851 - 7776 = 75
      expect(_words()[75], 'afraid');
      expect(approvalPhrase(_key(1), _words()).split(' ').last, 'afraid');
    });

    test('another key gives another phrase', () {
      expect(approvalPhrase(_key(1), _words()), isNot(approvalPhrase(_key(2), _words())));
    });

    test('a key or a list of the wrong size is refused', () {
      expect(() => approvalPhrase(Uint8List(1599), _words()), throwsA(isA<MalformedException>()));
      expect(() => approvalPhrase(_key(1), _words().sublist(1)), throwsA(isA<MalformedException>()));
    });
  });

  group('phrasesAgree', () {
    test('ignores case and spacing, and sees a different word', () {
      expect(phrasesAgree('slurp series primary ruined afraid', ' Slurp  series primary ruined AFRAID '), isTrue);
      expect(phrasesAgree('slurp series primary ruined afraid', 'slurp series primary ruined apron'), isFalse);
      expect(phrasesAgree('slurp series primary ruined afraid', ''), isFalse);
    });
  });

  test('phraseWords splits a phrase', () {
    expect(phraseWords('Slurp series  primary ruined afraid'), ['slurp', 'series', 'primary', 'ruined', 'afraid']);
  });
}
