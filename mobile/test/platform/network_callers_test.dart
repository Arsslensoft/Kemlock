import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What opens a connection, or hands one to something that does: the HTTP
/// clients, raw sockets, the browser (a launch or the SSO sheet's channel).
final _callers = RegExp(
  r'\bhttp\.Client\(|\bIOClient\(|\bHttpClient\(|\bSocket\.connect\b|\bSecureSocket\.connect\b|\bWebSocket\.connect\b|\blaunchUrl\(|com\.kemlock\.app/browser_auth',
);

/// The files under `lib/` that name a network caller, as paths from `lib/`, and those of
/// the builds' parts under `packages/` (openspec: add-fdroid-release), as paths from
/// `mobile/`.
List<String> filesWithNetworkCallers() {
  final roots = [
    Directory('lib'),
    for (final package in Directory('packages').listSync().whereType<Directory>()) Directory('${package.path}/lib'),
  ];
  final found = <String>[];
  for (final root in roots.where((root) => root.existsSync())) {
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final code = file.readAsLinesSync().where((line) => !line.trimLeft().startsWith('//')).join('\n');
      final path = file.path.replaceAll(r'\', '/');
      if (_callers.hasMatch(code)) found.add(path.startsWith('lib/') ? path.substring('lib/'.length) : path);
    }
  }
  return found..sort();
}

/// The only files that may name one: the gate itself, and the three it or a
/// provider wraps (the browser, and the pinned Vaultwarden client and its
/// certificate probe).
const _allowed = {
  'features/sync/vaultwarden/vw_http.dart',
  'platform/browser_auth.dart',
  'platform/links.dart',
  'platform/network.dart',
};

void main() {
  // openspec: add-offline-mode, design decision 3. A new caller goes through `platform/network.dart`:
  // `gatedClientProvider`, `gatedClientFactory` or `NetworkGate.check`.
  test('nothing outside the gate and the files it wraps opens a connection, the browser or the store', () {
    final outside = filesWithNetworkCallers().where((file) => !_allowed.contains(file)).toList();

    expect(outside, isEmpty, reason: 'These files make a client, a socket, a browser launch or a store call without the gate.');
  });

  // add-kemlock-server-sync, task 3.3: the client takes the app's gated, pinned client and makes none
  test('the Kemlock Server client makes no client, socket or browser launch of its own', () {
    final kemlock = filesWithNetworkCallers().where((file) => file.startsWith('features/sync/kemlock/')).toList();

    expect(kemlock, isEmpty);
    expect(Directory('lib/features/sync/kemlock').existsSync(), isTrue);
  });

  test('every file the guard lets through still exists', () {
    for (final file in _allowed) {
      expect(File(file.startsWith('packages/') ? file : 'lib/$file').existsSync(), isTrue, reason: file);
    }
  });
}
