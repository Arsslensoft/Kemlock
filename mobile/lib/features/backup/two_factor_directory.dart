// Where to manage 2FA and get new backup codes for ~1,600 services, from a
// copy of 2fa.directory bundled with the app (MIT licence inside the data file).
// assets/data/two_factor_directory.json is src/data/twoFactorDirectory.json copied as
// it is; refresh that with `npm run update:2fa-directory` and copy it again.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/service_names.dart';

/// One service in the directory.
class DirectoryEntry {
  const DirectoryEntry({required this.name, required this.domain, this.docs, this.recovery});

  final String name;
  final String domain;

  /// How to set up 2FA, which is also where new backup codes are made.
  final String? docs;

  /// What to do when the 2FA device or codes are lost.
  final String? recovery;

  @override
  String toString() => 'DirectoryEntry($name, $domain, docs: $docs, recovery: $recovery)';
}

/// The bundled 2FA directory, indexed by the keys of each service's names.
class TwoFactorDirectory {
  TwoFactorDirectory._(this.source, this.updated, this.license, this.entries, this._byKey);

  /// Indexes the directory's JSON: rows of `[name, domain, docs or 0, recovery or 0, other names?]`.
  /// A key goes to the first service that has it.
  factory TwoFactorDirectory.fromJson(Map<String, Object?> json) {
    final entries = <DirectoryEntry>[];
    final byKey = <String, DirectoryEntry>{};
    for (final row in (json['entries'] as List<Object?>? ?? const []).cast<List<Object?>>()) {
      final [name as String, domain as String, docs, recovery, ...rest] = row;
      final entry = DirectoryEntry(name: name, domain: domain, docs: _link(docs), recovery: _link(recovery));
      entries.add(entry);
      final more = rest.isEmpty ? const <String>[] : (rest.first! as List<Object?>).cast<String>();
      for (final alias in [name, domain, ...more]) {
        for (final key in keysFor(alias)) {
          byKey.putIfAbsent(key, () => entry);
        }
      }
    }
    return TwoFactorDirectory._(
      json['source'] as String? ?? '',
      json['updated'] as String?,
      json['license'] as String? ?? '',
      List.unmodifiable(entries),
      byKey,
    );
  }

  static const asset = 'assets/data/two_factor_directory.json';

  /// Where the data comes from: https://2fa.directory.
  final String source;

  /// The day the copy was made, `yyyy-mm-dd`.
  final String? updated;

  /// The data's MIT licence, to show with it.
  final String license;

  /// Every service, in the data's order.
  final List<DirectoryEntry> entries;

  /// The services by the keys of their names (see [keysFor]).
  final Map<String, DirectoryEntry> _byKey;

  static Future<TwoFactorDirectory>? _bundled;

  /// The directory, read from [bundle] (the app's own by default) the first time it is
  /// needed: at ~180 kB it would only slow down every start.
  static Future<TwoFactorDirectory> load({AssetBundle? bundle}) async {
    if (bundle != null) return _read(bundle);
    try {
      return await (_bundled ??= _read(rootBundle));
    } catch (_) {
      _bundled = null;
      rethrow;
    }
  }

  static Future<TwoFactorDirectory> _read(AssetBundle bundle) async =>
      TwoFactorDirectory.fromJson(jsonDecode(await bundle.loadString(asset, cache: false)) as Map<String, Object?>);

  /// The directory's entry for a service name, or null when it has none.
  DirectoryEntry? findService(String name) {
    for (final key in keysFor(name)) {
      final entry = _byKey[key];
      if (entry != null) return entry;
    }
    return null;
  }

  /// A link, or null for the data's 0 (or an empty string) for none.
  static String? _link(Object? value) => value is String && value.isNotEmpty ? value : null;
}

/// The 2FA directory, loaded on first watch and kept. Watch it only where it is shown, such
/// as an open backup card: `ref.watch(twoFactorDirectoryProvider).value`.
final twoFactorDirectoryProvider = FutureProvider<TwoFactorDirectory>((ref) => TwoFactorDirectory.load());
