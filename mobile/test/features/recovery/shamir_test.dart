import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/recovery/shamir.dart';

final _secret = Uint8List.fromList([for (var i = 0; i < 32; i++) (i * 37 + 11) & 0xff]);

/// Every way of choosing [k] items from a list.
List<List<T>> _choose<T>(List<T> items, int k) {
  if (k == 0) return [<T>[]];
  return [
    for (var i = 0; i < items.length; i++)
      for (final rest in _choose(items.sublist(i + 1), k - 1)) [items[i], ...rest],
  ];
}

/// A random source that always draws [byte].
class _Constant implements Random {
  _Constant(this.byte);

  final int byte;

  @override
  int nextInt(int max) => byte;

  @override
  double nextDouble() => throw UnimplementedError();

  @override
  bool nextBool() => throw UnimplementedError();
}

Matcher _throwsRange(String message) => throwsA(isA<RangeError>().having((e) => '${e.message}', 'message', contains(message)));

void main() {
  group('Shamir secret sharing', () {
    for (final (threshold, count) in [(1, 1), (2, 3), (3, 5), (5, 5)]) {
      test('rebuilds the secret from any $threshold of $count shares', () {
        final shares = split(_secret, threshold, count);

        expect([for (final s in shares) s.x], [for (var i = 1; i <= count; i++) i]);
        for (final subset in _choose(shares, threshold)) {
          expect(combine(subset), _secret);
        }
      });
    }

    test('also rebuilds from more shares than needed', () {
      expect(combine(split(_secret, 2, 4)), _secret);
    });

    test('gets a wrong answer, not the secret, from too few shares', () {
      final shares = split(_secret, 3, 5);

      expect(combine(shares.sublist(0, 2)), isNot(_secret));
    });

    test('makes a 1-of-1 share that is the secret itself', () {
      expect(split(_secret, 1, 1)[0].y, _secret);
    });

    test('keeps shares from depending on the secret alone', () {
      // Two splits of the same secret must not hand out the same shares
      final a = split(_secret, 2, 2);
      final b = split(_secret, 2, 2);

      expect(a[0].y, isNot(b[0].y));
    });

    test('matches a split worked out by hand', () {
      // p(x) = 0x42 ⊕ 0x07·x, so p(1) = 0x45 and p(2) = 0x42 ⊕ 0x0e = 0x4c
      final shares = split(Uint8List.fromList([0x42]), 2, 2, random: _Constant(0x07));

      expect([for (final s in shares) s.y[0]], [0x45, 0x4c]);
      expect(combine(shares), [0x42]);
    });

    test('rejects impossible thresholds', () {
      expect(() => split(_secret, 0, 3), throwsRangeError);
      expect(() => split(_secret, 4, 3), throwsRangeError);
      expect(() => split(_secret, 2, 256), throwsRangeError);
    });

    test('rejects duplicate or mismatched shares', () {
      final [one, two] = split(_secret, 2, 2);

      expect(() => combine([one, one]), _throwsRange('Duplicate shares'));
      expect(() => combine([one, Share(x: two.x, y: two.y.sublist(1))]), _throwsRange('different splits'));
      expect(() => combine([]), _throwsRange('No shares'));
    });

    test('rejects shares from outside the field', () {
      final [one, two] = split(_secret, 2, 2);

      expect(() => combine([one, Share(x: 0, y: two.y)]), _throwsRange('different splits'));
      expect(() => combine([one, Share(x: 256, y: two.y)]), _throwsRange('different splits'));
    });
  });
}
