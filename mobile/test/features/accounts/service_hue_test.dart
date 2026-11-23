import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/accounts/service_hue.dart';

void main() {
  // The hues the web app's serviceHue gives, so each service keeps its colour on the switch.
  for (final (name, hue) in [
    ('GitHub', 138),
    (' github ', 138),
    ('Bitw\u{e4}rden', 174),
    ('', 7),
    ('Google:alice@gmail.com', 7),
    ('\u{1f600} Emoji', 352), // UTF-16 code units, as JavaScript counts them
    ('\u{130}stanbul', 22), // which JavaScript lowercases to "i" and a combining dot
    ('\u{3a3}\u{391}\u{3a3}', 357), // which ends in a final sigma
    ('A long service name that overflows thirty two bits many times', 353),
  ]) {
    test('gives "$name" the hue $hue', () {
      expect(serviceHue(name), hue);
    });
  }
}
