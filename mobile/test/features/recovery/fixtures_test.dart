// The Recovery Kit against what the Capacitor app made (test/fixtures/recovery,
// written by the TypeScript modules themselves through
// tool/fixtures/recovery_fixtures.mjs). If any of these fail, a kit printed by
// the current app would not rebuild its key in this one, or the other way round.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/recovery/recovery_shares.dart';
import 'package:kemlock/features/recovery/shamir.dart';

typedef _Json = Map<String, Object?>;

final _fixtures = jsonDecode(File('test/fixtures/recovery/pieces.json').readAsStringSync()) as _Json;

List<_Json> _cases(String key) => [for (final item in _fixtures[key]! as List<Object?>) item! as _Json];

List<String> _strings(Object? list) => [for (final item in list! as List<Object?>) item! as String];

Uint8List _bytes(Object? hex) {
  final text = hex! as String;
  return Uint8List.fromList([for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)]);
}

String _hex(List<int> bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();

/// Every way of choosing [k] items from a list.
List<List<T>> _choose<T>(List<T> items, int k) {
  if (k == 0) return [<T>[]];
  return [
    for (var i = 0; i < items.length; i++)
      for (final rest in _choose(items.sublist(i + 1), k - 1)) [items[i], ...rest],
  ];
}

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

/// Hands out, byte by byte, what the TypeScript drew from `crypto.getRandomValues`.
class _Replay implements Random {
  _Replay(this._bytes);

  final Uint8List _bytes;
  var _next = 0;

  /// Whether every byte was drawn, no more and no fewer.
  bool get done => _next == _bytes.length;

  @override
  int nextInt(int max) {
    expect(max, 256);
    return _bytes[_next++];
  }

  @override
  double nextDouble() => throw UnimplementedError();

  @override
  bool nextBool() => throw UnimplementedError();
}

void main() {
  test('allows as many pieces', () {
    expect(maxPieces, _fixtures['maxPieces']);
  });

  group('Shamir, against the TypeScript', () {
    for (final fixture in _cases('shamir')) {
      final secret = _bytes(fixture['secret']);
      final threshold = fixture['threshold']! as int;
      final count = fixture['count']! as int;
      final name = '$threshold of $count, ${secret.length} bytes';

      test('splits $name as it did, from the same random bytes', () {
        final random = _Replay(_bytes(fixture['random']));

        final shares = split(secret, threshold, count, random: random);

        expect(random.done, isTrue);
        expect([
          for (final s in shares) {'x': s.x, 'y': _hex(s.y)},
        ], fixture['shares']);
      });

      test('rebuilds $name from its shares', () {
        final shares = [
          for (final share in (fixture['shares']! as List<Object?>).cast<_Json>()) Share(x: share['x']! as int, y: _bytes(share['y'])),
        ];
        // All of a small split; the first and last five of a large one
        final pool = count <= 9 ? shares : [...shares.take(5), ...shares.skip(count - 5)];

        for (final subset in _choose(pool, threshold)) {
          expect(combine(subset), secret, reason: 'x = ${[for (final s in subset) s.x]}');
          expect(combine(subset.reversed.toList()), secret);
        }
        final fewer = fixture['fewer'] as _Json?;
        if (fewer != null) {
          final xs = (fewer['xs']! as List<Object?>).cast<int>();
          expect(_hex(combine([for (final x in xs) shares[x - 1]])), fewer['result']);
        }
      });
    }
  });

  group('Kits the TypeScript made', () {
    for (final kit in _cases('kits')) {
      final threshold = kit['threshold']! as int;
      final shares = kit['shares']! as int;
      final pieces = _strings(kit['pieces']);
      final name = '$threshold-of-$shares kit';

      test('reads the pieces of a $name', () {
        final displayed = _strings(kit['displayed']);
        final ys = _strings(kit['y']);
        for (var i = 0; i < pieces.length; i++) {
          final piece = parsePiece(pieces[i]);

          expect(piece.kitId, kit['kitId']);
          expect(piece.threshold, threshold);
          expect(piece.shares, shares);
          expect(piece.index, i + 1);
          expect(_hex(piece.y), ys[i]);
          expect(pieceText(piece), pieces[i]);
          expect(displayPiece(pieces[i]), displayed[i]);
          expect(pieceText(parsePiece(displayed[i].toLowerCase())), pieces[i]);
        }
      });

      test('rebuilds the key of a $name from any $threshold pieces', () {
        final parsed = pieces.map(parsePiece).toList();

        for (final subset in _choose(parsed, threshold)) {
          expect(_hex(rebuildKey(subset)), kit['key'], reason: 'pieces ${[for (final p in subset) p.index]}');
          expect(_hex(rebuildKey(subset.reversed.toList())), kit['key']);
        }
        if (threshold > 1) expect(_problem(() => rebuildKey(parsed.sublist(1, threshold))), 'notEnough');
      });

      test('catches a piece of a $name mistyped anywhere', () {
        for (final text in pieces) {
          // Every character after the prefix, the dashes left alone; the three numbers are at 17–19
          for (var i = 'BMCKIT1-'.length; i < text.length; i++) {
            if (text[i] == '-') continue;
            final digit = i >= 17 && i <= 19;
            final swap = digit ? (text[i] == '1' ? '2' : '1') : (text[i] == 'A' ? 'B' : 'A');
            final typo = text.substring(0, i) + swap + text.substring(i + 1);

            expect(_problem(() => parsePiece(typo)), 'checksum', reason: typo);
          }
        }
      });

      test('makes a $name as it did, from the same random bytes', () {
        final random = _Replay(_bytes(kit['random']));

        final made = makeKit(threshold, shares, random: random);

        expect(random.done, isTrue);
        expect(made.kitId, kit['kitId']);
        expect(_hex(made.key), kit['key']);
        expect(made.pieces, pieces);
      });

      test('makes a $name of the same shape', () {
        final made = makeKit(threshold, shares);

        expect(made.pieces, hasLength(pieces.length));
        for (var i = 0; i < pieces.length; i++) {
          final ours = made.pieces[i].split('-');
          final theirs = pieces[i].split('-');

          expect([for (final part in ours) part.length], [for (final part in theirs) part.length]);
          expect(ours[0], theirs[0]);
          expect(ours[2], theirs[2]);
          expect(made.pieces[i], matches(RegExp('^BMCKIT1-${made.kitId}-$threshold$shares${i + 1}-[A-Z2-7]{52}-[A-Z2-7]{4}\$')));
        }
        expect(rebuildKey(made.pieces.reversed.take(threshold).map(parsePiece).toList()), made.key);
      });
    }
  });

  group('Typed pieces, read as the TypeScript read them', () {
    final cases = _cases('parse');
    for (var n = 0; n < cases.length; n++) {
      final fixture = cases[n];
      final input = fixture['input']! as String;
      final problem = fixture['problem'] as String?;

      test('#${n + 1} ${problem ?? 'reads'}: ${jsonEncode(input)}', () {
        if (problem != null) {
          expect(_problem(() => parsePiece(input)), problem);
          return;
        }
        final piece = parsePiece(input);
        final expected = fixture['piece']! as _Json;

        expect({
          'kitId': piece.kitId,
          'threshold': piece.threshold,
          'shares': piece.shares,
          'index': piece.index,
          'y': _hex(piece.y),
        }, expected);
        expect(pieceText(piece), fixture['text']);
      });
    }
  });

  group('Pieces displayed as the TypeScript displayed them', () {
    for (final fixture in _cases('display')) {
      test(jsonEncode(fixture['input']), () {
        expect(displayPiece(fixture['input']! as String), fixture['output']);
      });
    }
  });
}
