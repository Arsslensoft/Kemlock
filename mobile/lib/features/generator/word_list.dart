// EFF's large word list for passphrases (https://www.eff.org/dice, CC BY 3.0
// US), bundled as EFF serves it: 7,776 lines of five dice digits, a tab and a
// word.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const effWordListAsset = 'assets/data/eff_large_wordlist.txt';

/// The words of the list's [text], in its order.
List<String> parseWordList(String text) => [
  for (final line in text.split('\n'))
    if (line.split('\t') case [_, final word] when word.trim().isNotEmpty) word.trim(),
];

/// The bundled list, read once.
final wordListProvider = FutureProvider<List<String>>((ref) async => parseWordList(await rootBundle.loadString(effWordListAsset)));
