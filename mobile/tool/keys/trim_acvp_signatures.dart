// Trims NIST ACVP-Server internalProjection.json files of ML-DSA signature
// generation and verification to a few ML-DSA-65 cases of the external,
// pure interface (FIPS 204 Algorithms 2 and 3), keeping NIST's field names,
// test group and test case ids. Run it from mobile/:
//
//   dart run tool/keys/trim_acvp_signatures.dart <acvp download dir> <output dir>
//
// The download dir has sigGen/ and sigVer/, each holding the
// internalProjection.json of ML-DSA-sigGen-FIPS204 and ML-DSA-sigVer-FIPS204
// at commit [commit] of https://github.com/usnistgov/ACVP-Server.
//
// Run once on 2026-11-17 to make test/fixtures/keys/acvp/ml-dsa-65-sigGen.json
// and ml-dsa-65-sigVer.json; never rerun over them.

import 'dart:convert';
import 'dart:io';

/// The ACVP-Server master commit the two files were downloaded at.
const commit = '975de31eb83d87039ec88934fdc47d8c312b892d';

/// The cases kept, by test group id: deterministic and hedged signing, and
/// verification of good signatures and of each kind of bad one NIST makes
/// (a changed z, hint, commitment or message, two of each). They take in
/// a 1-byte and an 8192-byte message and an empty and a 255-byte context.
const sigGenCases = {
  3: [35, 39, 40, 41, 42, 44],
  15: [211, 212, 213, 214, 215, 216],
};
const sigVerCases = {
  3: [31, 32, 33, 34, 35, 36, 38, 39, 42, 43, 44],
};

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/keys/trim_acvp_signatures.dart <acvp download dir> <output dir>');
    exit(64);
  }
  final [src, out] = args;
  trim(
    '$src/sigGen/internalProjection.json',
    '$out/ml-dsa-65-sigGen.json',
    'ML-DSA-sigGen-FIPS204',
    sigGenCases,
    groupFields: ['deterministic', 'signatureInterface', 'preHash'],
    testFields: ['pk', 'sk', 'message', 'context', 'rnd', 'signature'],
  );
  trim(
    '$src/sigVer/internalProjection.json',
    '$out/ml-dsa-65-sigVer.json',
    'ML-DSA-sigVer-FIPS204',
    sigVerCases,
    groupFields: ['signatureInterface', 'preHash'],
    testFields: ['pk', 'message', 'context', 'signature', 'testPassed', 'reason'],
  );
}

void trim(
  String from,
  String to,
  String name,
  Map<int, List<int>> cases, {
  required List<String> groupFields,
  required List<String> testFields,
}) {
  final target = File(to);
  if (target.existsSync()) {
    stderr.writeln('$to exists; the ACVP fixtures are never remade');
    exit(1);
  }
  final doc = jsonDecode(File(from).readAsStringSync()) as Map<String, Object?>;
  final groups = (doc['testGroups']! as List<Object?>).cast<Map<String, Object?>>();
  final kept = <Map<String, Object?>>[];
  for (final MapEntry(key: tgId, value: ids) in cases.entries) {
    final group = groups.singleWhere((g) => g['tgId'] == tgId);
    if (group['parameterSet'] != 'ML-DSA-65' || group['signatureInterface'] != 'external' || group['preHash'] != 'pure') {
      throw StateError('$name test group $tgId is not ML-DSA-65, external and pure');
    }
    final tests = {for (final t in (group['tests']! as List<Object?>).cast<Map<String, Object?>>()) t['tcId']: t};
    kept.add({
      'tgId': tgId,
      'parameterSet': group['parameterSet'],
      for (final f in groupFields) f: group[f],
      'tests': [
        for (final id in ids)
          {
            'tcId': id,
            for (final f in testFields)
              if (tests[id]!.containsKey(f)) f: tests[id]![f],
          },
      ],
    });
  }
  final trimmed = {
    'source':
        'https://github.com/usnistgov/ACVP-Server at $commit, gen-val/json-files/$name '
        '(internalProjection.json, vsId ${doc['vsId']}), ML-DSA-65 external pure cases only',
    'testGroups': kept,
  };
  target.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(trimmed)}\n');
}
