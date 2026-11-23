// The app's side of how a website becomes a site for duplicate matching: the
// Public Suffix List and the shared hosts, which `duplicate_rules.dart` takes
// as functions so that it stays free of Flutter.
import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;

import '../../core/public_suffixes.dart';
import '../autofill/autofill_copy.dart' show isSharedHost, registrableDomain;
import 'duplicate_normalise.dart';

/// A [SiteResolver] that reads sites as `loginDomains` does: the registrable domain by
/// [suffixes] (the host as it is without the list), and an address or a shared host whole.
SiteResolver siteResolver({PublicSuffixList? suffixes}) => SiteResolver(
  registrable: (host) => registrableDomain(host, suffixes: suffixes),
  isShared: isSharedHost,
);

/// The hash of the Public Suffix List's [text], which the tag cache records: an app update that
/// changes the list changes how some sites read, so the tags are made again. `none` without the
/// list, where every host stands for itself.
String suffixListHash(String? text) => text == null ? 'none' : hash.sha256.convert(utf8.encode(text)).toString();
