import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/space_contact.dart';
import 'package:kemlock/features/spaces/space_state.dart';

import 'chain_kit.dart';

// First contact (the space chain section, "First contact" and its test case 13): who a device compares, what it
// compares, and that a chain a server made with its own Owner key shows another fingerprint than the real inviter's.
void main() {
  final space = uuid(0x5a);
  final alice = Person(1); // the Owner
  final bob = Person(2);
  final carol = Person(3);
  final dan = Person(4);
  final mallory = Person(9); // the server's own Owner

  FirstContact contactOf(ChainBuilder chain, Person who) => firstContact(state: chain.state, chain: chain.entries, account: who.id);

  test('the creator is their own anchor', () {
    final chain = ChainBuilder(space)..create(alice);
    expect(contactOf(chain, alice).kind, ContactKind.creator);
    expect(contactOf(chain, alice).canCompare, isFalse);
  });

  test('an invitee compares the inviter\'s fingerprint as the chain records it at its head', () {
    final chain = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob);
    final contact = contactOf(chain, bob);
    expect(contact.kind, ContactKind.compare);
    expect(contact.person, alice.id);
    expect(contact.admittedAt, 1);
    expect(contact.bundleSigned, isTrue, reason: 'the invite is itself a record the inviter signed');
    expect(contact.canCompare, isTrue);
    expect(contact.fingerprint, alice.bundle.fingerprint);
    expect(contact.matches(alice.bundle.fingerprint), isTrue);
    expect(contact.matches(carol.bundle.fingerprint), isFalse);
    expect(contact.matches(<int>[1, 2, 3]), isFalse);
  });

  test('13: a chain the server made with its own Owner key shows the server\'s fingerprint, never the real inviter\'s', () {
    final fake = ChainBuilder(space)
      ..create(mallory)
      ..invite(mallory, bob);
    final contact = contactOf(fake, bob);
    expect(contact.person, mallory.id);
    expect(contact.matches(alice.bundle.fingerprint), isFalse, reason: 'the inviter\'s own screen shows alice\'s digits');
    final real = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob);
    expect(contactOf(real, bob).matches(alice.bundle.fingerprint), isTrue);
  });

  test('an inviter who is no longer a confirmed member leaves the person to pick a confirmed Owner', () {
    final chain = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, carol, role: SpaceRole.admin)
      ..confirm(alice, carol)
      ..invite(carol, bob)
      ..remove(alice, carol);
    final contact = contactOf(chain, bob);
    expect(contact.kind, ContactKind.pickOwner);
    expect(contact.candidates, [alice.id]);
    expect(contact.canCompare, isFalse);
    final picked = compareWith(state: chain.state, chain: chain.entries, person: alice.id, admittedAt: contact.admittedAt!);
    expect(picked.kind, ContactKind.compare);
    expect(picked.fingerprint, alice.bundle.fingerprint);
    expect(() => compareWith(state: chain.state, chain: chain.entries, person: carol.id, admittedAt: 3), throwsStateError);
  });

  test('a confirmed member\'s new device compares the confirmer', () {
    final chain = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob)
      ..confirm(alice, bob);
    final contact = contactOf(chain, bob);
    expect(contact.kind, ContactKind.compare);
    expect(contact.person, alice.id);
    expect(contact.admittedAt, 2);
    expect(contact.canCompare, isTrue);
  });

  test('a member whose own current key signed or cosigned a record after they were confirmed needs no comparison', () {
    final signed = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob, role: SpaceRole.admin)
      ..confirm(alice, bob)
      ..policies(bob, {'requireSso': true});
    expect(contactOf(signed, bob).kind, ContactKind.vouched);
    final rekeyed = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob)
      ..confirm(alice, bob)
      ..rekey(bob, bob.withNewKeys());
    expect(contactOf(rekeyed, bob).kind, ContactKind.vouched);
  });

  test('a comparison is not offered when the anchor person\'s current bundle signed nothing since the account was admitted', () {
    // bob (an Admin) invites dan, and then alice confirms a newer bundle of bob's: the invite was signed by the old key
    final chain = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob, role: SpaceRole.admin)
      ..confirm(alice, bob)
      ..invite(bob, dan)
      ..confirm(alice, bob.withNewKeys());
    final contact = contactOf(chain, dan);
    expect(contact.kind, ContactKind.compare);
    expect(contact.person, bob.id);
    expect(contact.bundleSigned, isFalse);
    expect(contact.canCompare, isFalse);
    expect(contact.matches(bob.withNewKeys().bundle.fingerprint), isFalse, reason: 'nothing to compare means no match');
    // Once bob's new key signs a record after the invite, there is
    final later = chain.fork()..policies(bob.withNewKeys(), {'requireSso': true});
    expect(contactOf(later, dan).canCompare, isTrue);
    expect(contactOf(later, dan).fingerprint, bob.withNewKeys().bundle.fingerprint);
  });

  test('an account that isn\'t in the space has nothing to compare', () {
    final chain = ChainBuilder(space)..create(alice);
    expect(() => contactOf(chain, bob), throwsStateError);
    final removed = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob)
      ..remove(alice, bob);
    expect(() => contactOf(removed, bob), throwsStateError);
  });

  test('the chain\'s later confirmation must record this device\'s own bundle byte for byte', () {
    final chain = ChainBuilder(space)
      ..create(alice)
      ..invite(alice, bob)
      ..confirm(alice, bob);
    final state = chain.state;
    expect(confirmRecordsOwnBundle(state, bob.id, bob.bundle), isTrue);
    expect(confirmRecordsOwnBundle(state, bob.id, bob.withNewKeys().bundle), isFalse);
    expect(confirmRecordsOwnBundle(state, carol.id, carol.bundle), isFalse);
    final invited =
        (ChainBuilder(space)
              ..create(alice)
              ..invite(alice, bob))
            .state;
    expect(confirmRecordsOwnBundle(invited, bob.id, bob.bundle), isFalse, reason: 'not confirmed yet');
  });
}
