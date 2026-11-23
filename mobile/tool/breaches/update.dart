// Writes assets/data/breaches.json, the copy of Have I Been Pwned's list of breaches that
// ships with the app, from its API: https://haveibeenpwned.com/api/v3/breaches, which
// needs no key. Run it from mobile/ before a release:
//
//   dart run tool/breaches/update.dart
//
// The list is trimmed by BreachList.fromHibp, the same code the app's own update uses.
// The data is under CC BY 4.0; the notice goes into the file with it.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:kemlock/features/breaches/breach_list.dart';

Future<void> main() async {
  final response = await http.get(
    Uri.parse('https://haveibeenpwned.com/api/v3/breaches'),
    // Have I Been Pwned answers 403 without one
    headers: {'User-Agent': 'Kemlock (tool/breaches/update.dart)'},
  );
  if (response.statusCode != 200) {
    stderr.writeln('Have I Been Pwned answered ${response.statusCode}.');
    exitCode = 1;
    return;
  }
  final breaches = jsonDecode(utf8.decode(response.bodyBytes)) as List<Object?>;
  final list = BreachList.fromHibp(breaches, updated: DateTime.now().toUtc().toIso8601String().substring(0, 10));
  final json = list.toJson();
  // A breach to a line, so a refresh shows as the breaches added
  final text = StringBuffer()
    ..write('{"source":${jsonEncode(json['source'])},"updated":${jsonEncode(json['updated'])},')
    ..write('"license":${jsonEncode(json['license'])},"entries":[\n')
    ..write([for (final breach in list.entries) jsonEncode(breach.toRow())].join(',\n'))
    ..write('\n]}\n');
  File(BreachList.asset).writeAsStringSync(text.toString());
  stdout.writeln('${list.entries.length} of ${breaches.length} breaches written to ${BreachList.asset}.');
}
