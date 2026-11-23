import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/lookup/key_search.dart';
import 'package:kemlock/features/contacts/lookup/vks.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/platform/network.dart';

import '../contacts_kit.dart';
import 'lookup_kit.dart';

/// The search over the two services (openspec: add-key-lookup, task 3.1), against a fake resolver and a
/// MockClient, with the answers of `test/fixtures/keys/lookup`.
void main() {
  late FakeKeyServices services;
  late bool offline;
  late KeySearch search;
  late List<KeySearchState> seen;

  setUp(() {
    services = FakeKeyServices();
    offline = false;
    search = KeySearch(
      gate: NetworkGate(() => offline),
      client: services.client,
      resolve: services.resolve,
      read: readKeysForAddress,
      now: () => contactsNow,
    );
    seen = [];
    search.addListener(() => seen.add(search.value));
    addTearDown(search.dispose);
  });

  final grace = addressOf('grace@example.org');
  final alan = addressOf('alan@example.org');

  test('a key at the domain is found there, and the key server is never asked', () async {
    services.directory('grace@example.org', lookupAnswer(wkdGrace));

    await search.search(grace);

    expect(seen.first, isA<SearchAskingDomain>());
    final found = search.value as SearchFound;
    expect((found.address, found.source, found.keys.single.info.primary.fingerprintHex), (grace, ContactSource.wkd, graceFingerprint));
    expect(services.keyServerRequests, isEmpty);
  });

  test('no key at the domain stops there until the person accepts the key server, which then finds one', () async {
    services
      ..emptyDirectory('alan@example.org')
      ..keyServer('alan@example.org', 200, lookupAnswer(vksAlan));

    await search.search(alan);

    expect(search.value, isA<SearchDomainHasNone>());
    expect(search.canAskKeyServer, isTrue);
    expect(services.keyServerRequests, isEmpty);

    await search.askKeyServer();

    expect(seen.whereType<SearchAskingServer>(), hasLength(1));
    final found = search.value as SearchFound;
    expect((found.source, found.keys.single.info.primary.fingerprintHex), (ContactSource.keyserver, alanFingerprint));
    expect(services.keyServerRequests, [vksUri(alan)]);
  });

  test('the next search starts with the key server not accepted', () async {
    services
      ..emptyDirectory('alan@example.org')
      ..emptyDirectory('grace@example.org');
    await search.search(alan);
    await search.askKeyServer();
    expect(search.value, isA<SearchNowhere>());

    await search.search(grace);

    expect(search.value, isA<SearchDomainHasNone>());
    expect(services.keyServerRequests, [vksUri(alan)]);
  });

  test('a key that fails its own checks counts as no key, as does one for another address', () async {
    services.directory('grace@example.org', keyBytes('contacts/grace-1.foreign-subkey.public.asc'));
    await search.search(grace);
    expect(search.value, isA<SearchDomainHasNone>());

    services.directory('grace@example.org', lookupAnswer(wkdAlan));
    await search.search(grace);
    expect(search.value, isA<SearchDomainHasNone>());

    services.keyServer('grace@example.org', 200, lookupAnswer(vksAlan));
    await search.askKeyServer();
    expect(search.value, isA<SearchNowhere>());
  });

  test('a key that fails its own checks does not take a sound key of the same answer with it', () async {
    services.directory('grace@example.org', [...keyBytes('contacts/grace-1.foreign-subkey.public.asc'), ...keyBytes(graceOther)]);

    await search.search(grace);

    final found = search.value as SearchFound;
    expect([for (final key in found.keys) key.info.primary.fingerprintHex], [graceOtherFingerprint]);
  });

  test('the keys found come in the order to review them, the valid one first', () async {
    services.directory('grace@example.org', lookupAnswer(wkdRevokedThenOther));

    await search.search(grace);

    expect(
      [for (final key in (search.value as SearchFound).keys) key.info.primary.fingerprintHex],
      [graceOtherFingerprint, graceFingerprint],
    );
  });

  test('offline mode pauses the search before anything is asked', () async {
    offline = true;
    services.directory('grace@example.org', lookupAnswer(wkdGrace));

    await search.search(grace);

    expect(search.value, isA<SearchPaused>().having((s) => s.step, 'step', KeySearchStep.domain));
    expect(services.resolved, isEmpty);
    expect(services.requests, isEmpty);
  });

  test('offline mode turned on between the two steps pauses the key server step', () async {
    services
      ..emptyDirectory('alan@example.org')
      ..keyServer('alan@example.org', 200, lookupAnswer(vksAlan));
    await search.search(alan);

    offline = true;
    await search.askKeyServer();

    expect(search.value, isA<SearchPaused>().having((s) => s.step, 'step', KeySearchStep.server));
    expect(services.keyServerRequests, isEmpty);

    // Once it is off again, the offer still stands
    offline = false;
    expect(search.canAskKeyServer, isTrue);
    await search.retry();
    expect(search.value, isA<SearchFound>());
  });

  test('a domain that could not be reached is asked again on retry, and only it', () async {
    await search.search(grace);
    expect(search.value, isA<SearchCouldNotAsk>().having((s) => s.step, 'step', KeySearchStep.domain));
    expect(search.canAskKeyServer, isFalse);

    services.directory('grace@example.org', lookupAnswer(wkdGrace));
    await search.retry();

    expect(search.value, isA<SearchFound>());
    expect(services.keyServerRequests, isEmpty);
  });

  test('a key server that could not be reached, or asked to slow down, is asked again on retry, and only it', () async {
    services
      ..emptyDirectory('alan@example.org')
      ..keyServer('alan@example.org', 500);
    await search.search(alan);
    await search.askKeyServer();
    expect(search.value, isA<SearchCouldNotAsk>().having((s) => s.step, 'step', KeySearchStep.server));

    services.keyServer('alan@example.org', 429);
    await search.retry();
    expect(search.value, isA<SearchSlowDown>());

    services
      ..keyServer('alan@example.org', 200, lookupAnswer(vksAlan))
      ..requests.clear();
    await search.retry();
    expect(search.value, isA<SearchFound>());
    expect(services.requests, [vksUri(alan)]);
  });

  test('the key server is not asked before the domain said it has none', () async {
    services.directory('grace@example.org', lookupAnswer(wkdGrace));

    await search.askKeyServer();
    expect(search.value, isA<SearchIdle>());

    await search.search(grace);
    await search.askKeyServer();
    expect(search.value, isA<SearchFound>());
    expect(services.keyServerRequests, isEmpty);
  });

  test('a search whose sheet closed on the way ends quietly, with nothing found', () async {
    services.directory('grace@example.org', lookupAnswer(wkdGrace));
    final closing = KeySearch(
      gate: NetworkGate(() => false),
      client: services.client,
      resolve: services.resolve,
      read: readKeysForAddress,
      now: () => contactsNow,
    );

    final asked = closing.search(grace);
    closing.dispose();
    await asked;

    expect(closing.value, isA<SearchAskingDomain>());
  });
}
