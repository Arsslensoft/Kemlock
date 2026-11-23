// A user ID is whatever the owner of a key wrote. Its name and address are
// read on the UI isolate for every key on screen, in one pass and with no
// pattern: what the patterns gave is kept here, to hold the readers to it.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/contacts/contact_keys.dart' as contacts;
import 'package:kemlock/features/keys/key_bridge.dart';
import 'package:kemlock/features/pgp/pgp_people.dart' as people;

/// `userIdAddress` as the patterns read it.
String? _addressByPattern(String userId) {
  final bracketed = RegExp(r'<([^<>\s]+@[^<>\s]+)>').firstMatch(userId)?.group(1);
  if (bracketed != null) return bracketed;
  final bare = userId.trim();
  return RegExp(r'^[^<>\s]+@[^<>\s]+$').hasMatch(bare) ? bare : null;
}

/// The contacts' `userIdName` as the pattern read it.
String _contactNameByPattern(String userId) {
  final cut = userId.indexOf('<');
  final name = (cut < 0 ? userId : userId.substring(0, cut)).replaceAll(RegExp(r'\([^)]*\)'), '').trim();
  if (name.isNotEmpty && _addressByPattern(name) == null) return name;
  return _addressByPattern(userId) ?? userId.trim();
}

/// The PGP sheets' `userIdName` as the patterns read it.
String? _personNameByPattern(String userId) {
  final trimmed = userId.trim();
  if (trimmed.isEmpty) return null;
  final angle = trimmed.indexOf('<');
  if (angle <= 0) return trimmed.replaceAll(RegExp(r'^<|>$'), '');
  final name = trimmed.substring(0, angle).replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
  return name.isEmpty ? trimmed.substring(angle + 1).replaceAll('>', '').trim() : name;
}

void main() {
  test('the address of a user ID', () {
    expect(userIdAddress('Ada Lovelace <ada@example.org>'), 'ada@example.org');
    expect(userIdAddress('Ada Lovelace (work) <ada@example.org>'), 'ada@example.org');
    expect(userIdAddress('ada@example.org'), 'ada@example.org');
    expect(userIdAddress('  ada@example.org\n'), 'ada@example.org');
    expect(userIdAddress('Ada Lovelace'), isNull);
    expect(userIdAddress(''), isNull);
    // The first pair of brackets that holds an address and nothing else
    expect(userIdAddress('<not one> <ada@example.org> <other@example.org>'), 'ada@example.org');
    expect(userIdAddress('Ada <ada @example.org>'), isNull);
    expect(userIdAddress('Ada <<ada@example.org>'), 'ada@example.org');
    expect(userIdAddress('Ada <ada@example.org'), isNull);
    // Something on each side of the @, which may come more than once
    expect(userIdAddress('<@example.org>'), isNull);
    expect(userIdAddress('<ada@>'), isNull);
    expect(userIdAddress('<a@b@c>'), 'a@b@c');
    expect(userIdAddress('@'), isNull);
    expect(userIdAddress('a@b'), 'a@b');
    expect(userIdAddress('ada@example.org and more'), isNull);
  });

  test('the name of a user ID, for a contact and for a PGP sheet', () {
    expect(contacts.userIdName('Grace Hopper (Navy) <grace@example.org>'), 'Grace Hopper');
    expect(contacts.userIdName('Grace (a) Hopper (b)'), 'Grace  Hopper');
    expect(contacts.userIdName('<grace@example.org>'), 'grace@example.org');
    expect(contacts.userIdName('(only a comment'), '(only a comment');
    expect(contacts.userIdName('  '), '');

    expect(people.userIdName('Ada Lovelace <ada@example.org>'), 'Ada Lovelace');
    expect(people.userIdName('Ada Lovelace (work) <ada@example.org>'), 'Ada Lovelace');
    expect(people.userIdName('Ada (née Byron) Lovelace (work)  <ada@example.org>'), 'Ada (née Byron) Lovelace');
    expect(people.userIdName('(work) <ada@example.org>'), 'ada@example.org');
    expect(people.userIdName('<ada@example.org>'), 'ada@example.org');
    expect(people.userIdName('ada@example.org'), 'ada@example.org');
    expect(people.userIdName('  '), isNull);
  });

  test('they read what the patterns read, whatever the user ID', () {
    // Every character that the patterns told apart, and one of each kind of space
    const pieces = ['a', 'b', '@', '<', '>', '(', ')', ' ', '\t', '\n', '\u0085', ' ', ' ', '﻿', '.', 'é'];
    final random = Random(2048);
    for (var i = 0; i < 20000; i++) {
      final userId = [for (var n = random.nextInt(14); n > 0; n--) pieces[random.nextInt(pieces.length)]].join();
      final shown = userId.runes.map((r) => r.toRadixString(16)).join(' ');
      expect(userIdAddress(userId), _addressByPattern(userId), reason: shown);
      expect(contacts.userIdName(userId), _contactNameByPattern(userId), reason: shown);
      expect(people.userIdName(userId), _personNameByPattern(userId), reason: shown);
    }
  });

  test('a long user ID made to be slow takes no time', () {
    // Each of these took a pattern a time that grows with the square of its
    // length: seconds for a few thousand characters, hours for a megabyte
    const length = 1 << 20;
    final open = '(' * length;
    expect(contacts.userIdName(open), open);
    expect(contacts.userIdName('$open <ada@example.org>'), open);
    expect(people.userIdName('Ada $open ) <ada@example.org>'), 'Ada');
    expect(people.userIdName('Ada $open <ada@example.org>'), 'Ada $open');
    final ats = 'a@' * (length ~/ 2);
    expect(userIdAddress('<${ats}a'), isNull);
    expect(userIdAddress('${ats}a<'), isNull);
    expect(userIdAddress('<' * length), isNull);
    expect(userIdAddress('<${ats}a>'), '${ats}a');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
