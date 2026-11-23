import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../../models/contact.dart';
import '../../models/identity.dart';
import '../../models/login.dart';
import '../../models/passkey.dart';
import '../../models/payment_card.dart';
import '../../models/secure_note.dart';
import '../../models/vault_key.dart';
import '../../ui/ui.dart' show StatusTone;
import '../../vault/vault_controller.dart';
import '../keys/key_bridge.dart';
import '../keys/key_standing.dart';
import '../keys/ssh_fingerprint.dart';

/// What the Vault tab shows: everything, or one kind.
enum VaultFilter {
  all('vault.filter.all'),
  logins('vault.filter.logins'),
  cards('vault.filter.cards'),
  identities('vault.filter.identities'),
  keys('vault.filter.keys'),
  notes('vault.filter.notes'),
  passkeys('vault.filter.passkeys');

  const VaultFilter(this.labelId);

  final String labelId;
}

/// The kinds of item the Vault tab lists.
enum VaultItemKind {
  login(Icons.password_rounded, VaultFilter.logins),
  card(Icons.credit_card_rounded, VaultFilter.cards),
  identity(Icons.badge_outlined, VaultFilter.identities),
  key(Icons.key_rounded, VaultFilter.keys),
  note(Icons.sticky_note_2_outlined, VaultFilter.notes),
  passkey(Icons.fingerprint_rounded, VaultFilter.passkeys),

  /// Someone else's public key, listed under Keys in a section of its own.
  contact(Icons.person_outline_rounded, VaultFilter.keys);

  const VaultItemKind(this.icon, this.filter);

  final IconData icon;
  final VaultFilter filter;
}

/// What the list shows of a key beyond what the vault stores: for a PGP key,
/// read from the key itself and worked out against the clock; for an SSH
/// key, hashed from its public half.
@immutable
class KeyListing {
  const KeyListing({
    this.standing,
    this.tag,
    this.pgpLine,
    this.sshFingerprint,
    this.cardTag,
    this.cardWords,
    this.version6 = false,
    this.postQuantum = false,
  });

  /// A PGP key's standing; null for a key of another kind.
  final KeyStanding? standing;

  /// The words of the tag a key that needs attention carries, in the
  /// current language; null for a key in order.
  final String? tag;

  /// The address and algorithm under a PGP key's name in the Keys filter;
  /// null for another kind of key and for a PGP key that can't be read.
  final String? pgpLine;

  /// An SSH key's `SHA256:` fingerprint, whole; null for another kind of
  /// key and for an SSH key whose public half can't be read.
  final String? sshFingerprint;

  /// The words of the tag a key whose private half is on a security key
  /// carries ("On your key"), and more words it is found by; null for any
  /// other key (openspec: add-openpgp-card).
  final String? cardTag;
  final String? cardWords;

  /// A version 6 PGP key, which carries a "v6" tag (add-post-quantum-pgp).
  final bool version6;

  /// A PGP key with a post-quantum primary key or subkey, found by
  /// searching "post-quantum".
  final bool postQuantum;
}

/// What the list shows of a contact beyond what the vault stores, read from
/// its key and worked out against the clock.
@immutable
class ContactListing {
  const ContactListing({this.checked = false, this.line, this.standing, this.tag, this.userIds = const [], this.fingerprint});

  /// Whether the fingerprint of the key it holds was checked.
  final bool checked;

  /// "Checked on 3 November" or "Not checked yet", in the current language.
  final String? line;

  /// The key's standing; null for a key that can't be read.
  final KeyStanding? standing;

  /// The words of the tag an expiring, expired or revoked key carries.
  final String? tag;

  /// Every user ID of the key, which search reads.
  final List<String> userIds;

  /// The key's fingerprint in hexadecimal, which search reads.
  final String? fingerprint;
}

/// What the list shows of a login beyond what the vault stores: the words
/// of its tag in the current language and how the tag is coloured (a health
/// warning, or New and Code in the accent), and the line under its name
/// when it isn't the username ("Saved by AutoFill · 21 November").
@immutable
class LoginListing {
  const LoginListing({this.tag, this.tone, this.line});

  final String? tag;
  final StatusTone? tone;
  final String? line;
}

/// One row of the Vault tab: any kind of item, as the list shows it and
/// search reads it.
@immutable
class VaultListItem {
  const VaultListItem({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle,
    this.pinned = false,
    required this.addedAt,
    this.searchText = const [],
    this.standing,
    this.tag,
    this.isPgp = false,
    this.pgpLine,
    this.isSsh = false,
    this.fingerprint,
    this.cardTag,
    this.unchecked = false,
    this.version6 = false,
    this.tagTone,
  });

  /// A login: its name and username, found by those, its websites, note and
  /// tags, and its tag's words.
  factory VaultListItem.login(Login login, [LoginListing listing = const LoginListing()]) => VaultListItem(
    kind: VaultItemKind.login,
    id: login.id,
    title: login.name,
    subtitle: listing.line ?? login.username,
    pinned: login.isPinned,
    addedAt: login.addedAt,
    searchText: [login.name, ?login.username, ...?login.websites, ?login.note, ...?login.tags, ?listing.tag],
    tag: listing.tag,
    tagTone: listing.tone,
  );

  /// A card: its name, and the brand and last four digits under it, found by
  /// those, its cardholder and tags, and the words of its Expired tag. Never
  /// by its full number, security code or PIN.
  factory VaultListItem.card(PaymentCard card, {String? tag}) {
    final last = card.lastFour;
    final subtitle = last == null ? card.cardholder : [?card.brand, last].join(' · ');
    return VaultListItem(
      kind: VaultItemKind.card,
      id: card.id,
      title: card.name,
      subtitle: subtitle,
      pinned: card.isPinned,
      addedAt: card.addedAt,
      searchText: [card.name, ?card.cardholder, ?card.brand, ...?card.tags, ?last, ?tag],
      tag: tag,
      tagTone: tag == null ? null : StatusTone.danger,
    );
  }

  /// An identity: its name, and the person's full name or email under it,
  /// found by its name, the person's names, company, email and tags. Never by
  /// a phone number, an address or a document number.
  factory VaultListItem.identity(Identity identity) => VaultListItem(
    kind: VaultItemKind.identity,
    id: identity.id,
    title: identity.name,
    subtitle: identity.fullName ?? identity.email,
    pinned: identity.isPinned,
    addedAt: identity.addedAt,
    searchText: [
      identity.name,
      ?identity.givenName,
      ?identity.middleName,
      ?identity.familyName,
      ?identity.company,
      ?identity.email,
      ...?identity.tags,
    ],
  );

  /// A note: its title and the first line of its text, found by its text,
  /// tags and the names of its files.
  factory VaultListItem.note(SecureNote note) {
    final firstLine = note.text.trim().split('\n').first.trim();
    return VaultListItem(
      kind: VaultItemKind.note,
      id: note.id,
      title: note.title,
      subtitle: firstLine.isEmpty ? null : firstLine,
      pinned: note.isPinned,
      addedAt: note.addedAt,
      searchText: [note.title, note.text, ...?note.tags, for (final file in note.files) file.name],
    );
  }

  /// A key: its name and algorithm, found by those, its note and tags. A PGP
  /// key that is expiring, expired or revoked carries a tag saying so, and
  /// is found by the tag's words and by its address. An SSH key shows its
  /// fingerprint, shortened, where the algorithm would be, and is found by
  /// the whole fingerprint and still by its algorithm.
  factory VaultListItem.key(VaultKey key, [KeyListing listing = const KeyListing()]) => VaultListItem(
    kind: VaultItemKind.key,
    id: key.id,
    title: key.name,
    subtitle: key.kind == KeyKind.ssh && listing.sshFingerprint != null
        ? shortSshFingerprint(listing.sshFingerprint!)
        : algorithmLabel(key.algorithm, key.bits),
    pinned: key.isPinned,
    addedAt: key.addedAt,
    searchText: [
      key.name,
      algorithmLabel(key.algorithm, key.bits),
      key.kind,
      ?key.note,
      ...?key.tags,
      ?listing.tag,
      ?listing.pgpLine,
      if (key.kind == KeyKind.ssh) ?listing.sshFingerprint,
      ?listing.cardTag,
      ?listing.cardWords,
      if (listing.postQuantum) 'post-quantum',
      if (listing.version6) 'v6',
    ],
    standing: listing.standing,
    tag: listing.tag,
    isPgp: key.kind == KeyKind.pgp,
    pgpLine: listing.pgpLine,
    isSsh: key.kind == KeyKind.ssh,
    fingerprint: key.kind == KeyKind.ssh ? listing.sshFingerprint : null,
    cardTag: listing.cardTag,
    version6: listing.version6,
  );

  /// Someone's public key: the contact's name, the line saying whether it
  /// was checked, and its initials for the tile; found by its name, every
  /// user ID of its key and its fingerprint. A key that expired or was
  /// revoked carries the tag a PGP key of the vault's own does.
  factory VaultListItem.contact(Contact contact, [ContactListing listing = const ContactListing()]) => VaultListItem(
    kind: VaultItemKind.contact,
    id: contact.id,
    title: contact.name,
    subtitle: listing.line,
    addedAt: contact.addedAt,
    searchText: [contact.name, ...listing.userIds, ?listing.fingerprint, ?contact.note, ?listing.tag],
    standing: listing.standing,
    tag: listing.tag,
    unchecked: !listing.checked,
  );

  /// A passkey: what it is listed as, and the account it signs in to.
  factory VaultListItem.passkey(Passkey passkey) => VaultListItem(
    kind: VaultItemKind.passkey,
    id: passkey.id,
    title: passkey.displayName,
    subtitle: passkey.displayName == passkey.rpId ? passkey.userName : '${passkey.rpId} · ${passkey.userName}',
    addedAt: passkey.addedAt,
    searchText: [
      passkey.displayName,
      passkey.rpId,
      ?passkey.rpName,
      passkey.userName,
      ?passkey.userDisplayName,
      ?passkey.note,
      ...?passkey.tags,
    ],
  );

  final VaultItemKind kind;
  final String id;
  final String title;
  final String? subtitle;
  final bool pinned;
  final int addedAt;

  /// Everything a search looks through.
  final List<String> searchText;

  /// A PGP key's standing; null for anything else.
  final KeyStanding? standing;

  /// The words of the tag the row carries; null for none.
  final String? tag;

  /// Whether this is a PGP key, which the Keys filter lists in a group of its own.
  final bool isPgp;

  /// The address and algorithm written under a PGP key's name in that group.
  final String? pgpLine;

  /// Whether this is an SSH key, which the Keys filter lists under a label of its own.
  final bool isSsh;

  /// An SSH key's whole `SHA256:` fingerprint, which its row shows shortened
  /// as [subtitle] and reads out whole; null when it can't be worked out.
  final String? fingerprint;

  /// The words of the "On your key" tag of a key on a security key.
  final String? cardTag;

  /// A contact whose fingerprint was never checked, whose line is written
  /// in the warning colour; false for anything else.
  final bool unchecked;

  /// A version 6 PGP key, tagged "v6".
  final bool version6;

  /// How a login's [tag] is coloured; null for any other kind.
  final StatusTone? tagTone;

  /// Whether every word of [query] is in what search reads, ignoring case.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    final haystack = searchText.map((text) => text.toLowerCase()).toList();
    return words.every((word) => haystack.any((text) => text.contains(word)));
  }
}

/// The open vault's items as the Vault tab lists them, filtered by [filter]
/// and [query], pinned first, then by name. Under the Keys filter the PGP
/// keys come apart in [pgp], a group of their own with its pinned keys
/// first; under any other filter [pgp] is empty and they are listed with
/// the rest. The SSH keys that are not pinned come apart the same way in
/// [ssh], unless a search is on, whose results stay one list; a pinned SSH
/// key stays with the pinned items. [keyListings] holds what the list shows
/// of each PGP and SSH key, by id. Other people's keys come apart in
/// [contacts], under All and under Keys, by name; [contactListings] holds
/// what the list shows of each. The total counts them.
({
  List<VaultListItem> pgp,
  List<VaultListItem> ssh,
  List<VaultListItem> pinned,
  List<VaultListItem> rest,
  List<VaultListItem> contacts,
  int total,
})
vaultListItems(
  VaultState state, {
  VaultFilter filter = VaultFilter.all,
  String query = '',
  Map<String, KeyListing> keyListings = const {},
  Map<String, ContactListing> contactListings = const {},
  Map<String, LoginListing> loginListings = const {},
  Map<String, String> cardTags = const {},
}) {
  final all = [
    for (final login in state.logins) VaultListItem.login(login, loginListings[login.id] ?? const LoginListing()),
    for (final card in state.cards) VaultListItem.card(card, tag: cardTags[card.id]),
    for (final identity in state.identities) VaultListItem.identity(identity),
    for (final key in state.keys) VaultListItem.key(key, keyListings[key.id] ?? const KeyListing()),
    for (final note in state.notes) VaultListItem.note(note),
    for (final passkey in state.passkeys) VaultListItem.passkey(passkey),
  ];
  bool show(VaultListItem item) =>
      (filter == VaultFilter.all || item.kind.filter == filter) && (query.trim().isEmpty || item.matches(query));
  final shown = all.where(show).toList();
  // Other people's keys are never among the vault's own: a section of their own, never pinned
  final people = [
    for (final contact in state.contacts) VaultListItem.contact(contact, contactListings[contact.id] ?? const ContactListing()),
  ];
  int byName(VaultListItem a, VaultListItem b) {
    final name = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return name != 0 ? name : a.addedAt.compareTo(b.addedAt);
  }

  final grouped = filter == VaultFilter.keys ? shown.where((item) => item.isPgp).toList() : const <VaultListItem>[];
  bool inSshGroup(VaultListItem item) => filter == VaultFilter.keys && query.trim().isEmpty && item.isSsh && !item.pinned;
  final loose = filter == VaultFilter.keys ? shown.where((item) => !item.isPgp && !inSshGroup(item)).toList() : shown;
  return (
    pgp: [...grouped.where((item) => item.pinned).sorted(byName), ...grouped.where((item) => !item.pinned).sorted(byName)],
    ssh: shown.where(inSshGroup).sorted(byName),
    pinned: loose.where((item) => item.pinned).sorted(byName),
    rest: loose.where((item) => !item.pinned).sorted(byName),
    contacts: people.where(show).sorted(byName),
    total: all.length + people.length,
  );
}
