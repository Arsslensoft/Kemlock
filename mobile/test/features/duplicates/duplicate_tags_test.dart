import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/duplicates/duplicate_rules.dart';
import 'package:kemlock/features/duplicates/duplicate_tags.dart';
import 'package:kemlock/models/contact.dart';
import 'package:kemlock/models/identity.dart';

// What the duplicate finder tells a contact, a key and an identity by
void main() {
  List<TagKind> kinds(Object item, {String? identity}) => [
    for (final input in tagInputsOf(item, keyIdentityOf: (_) => identity)) input.kind,
  ];

  test('a person with an email or a phone is told by it, and one with a key by the key as well', () {
    const person = Contact(id: 'p1', name: 'Ada', source: ContactSource.manual, email: 'ada@example.org', addedAt: 0);

    expect(kinds(person), [TagKind.contact]);
    expect(kinds(person, identity: 'ab' * 20), [TagKind.contact, TagKind.key]);
    expect(kinds(const Contact(id: 'p2', name: 'Nobody', source: ContactSource.manual, addedAt: 0)), isEmpty);
  });

  test('two people with the same email in other case have the same contact tag', () {
    const a = Contact(id: 'p1', name: 'Ada', source: ContactSource.manual, email: 'ada@example.org', addedAt: 0);
    const b = Contact(id: 'p2', name: 'A. Lovelace', source: ContactSource.manual, email: ' ADA@Example.org', addedAt: 0);

    expect(tagInputsOf(a).single, tagInputsOf(b).single);
  });

  test('an identity is told by its documents too', () {
    const identity = Identity(
      id: 'i1',
      name: 'Me',
      documents: [IdentityDocument(id: 'd1', type: 'passport', number: 'X1234567')],
      addedAt: 0,
    );

    expect(kinds(identity), contains(TagKind.document));
  });
}
