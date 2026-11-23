import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';

/// The problem [run] reports, its error as text if it's no [PieceError], or 'no error'.
String _problem(Object? Function() run) {
  try {
    run();
  } on PieceError catch (e) {
    return e.problem.name;
  } catch (e) {
    return '$e';
  }
  return 'no error';
}

void main() {
  group('Recovery Kit pieces', () {
    test('writes each piece with its kit, numbers and a check', () {
      final kit = makeKit(2, 3);

      expect(kit.pieces, hasLength(3));
      for (var i = 0; i < kit.pieces.length; i++) {
        expect(kit.pieces[i], matches(RegExp('^BMCKIT1-${kit.kitId}-23${i + 1}-[A-Z2-7]{52}-[A-Z2-7]{4}\$')));
      }
    });

    test('rebuilds the key from any two of three pieces', () {
      final kit = makeKit(2, 3);
      final [a, b, c] = kit.pieces.map(parsePiece).toList();

      expect(rebuildKey([a, b]), kit.key);
      expect(rebuildKey([c, a]), kit.key);
    });

    test('reads a piece typed in lowercase with the display spaces kept', () {
      final pieces = makeKit(1, 1).pieces;
      final typed = displayPiece(pieces[0]).toLowerCase();

      expect(typed, contains(' '));
      expect(pieceText(parsePiece(typed)), pieces[0]);
    });

    test('catches a mistyped piece', () {
      final pieces = makeKit(2, 2).pieces;
      final text = pieces[0];
      final i = text.indexOf('-', 18) + 5;
      final typo = text.substring(0, i) + (text[i] == 'A' ? 'B' : 'A') + text.substring(i + 1);

      expect(_problem(() => parsePiece(typo)), 'checksum');
    });

    for (final text in ['', 'hello', 'BMCKIT1-ABCDEFGH-231-SHORT-AAAA', 'otpauth://totp/x?secret=ABC']) {
      test('rejects "$text" as no piece at all', () {
        expect(_problem(() => parsePiece(text)), 'format');
      });
    }

    test('refuses a second copy of a piece and a piece of another kit', () {
      final first = makeKit(2, 3).pieces.map(parsePiece).toList();
      final other = parsePiece(makeKit(2, 3).pieces[1]);

      final collected = addPiece([], first[0]);
      expect(_problem(() => addPiece(collected, first[0])), 'duplicate');
      expect(_problem(() => addPiece(collected, other)), 'otherKit');
      expect(addPiece(collected, first[2]), hasLength(2));
    });

    test('waits for enough pieces', () {
      final pieces = makeKit(3, 5).pieces.map(parsePiece).toList();

      expect(_problem(() => rebuildKey(pieces.sublist(0, 2))), 'notEnough');
      expect(_problem(() => rebuildKey([])), 'notEnough');
    });

    test('caps a kit at nine pieces so every number stays one digit', () {
      expect(() => makeKit(2, 10), throwsRangeError);
    });
  });
}
