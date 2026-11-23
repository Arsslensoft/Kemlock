/// Who asks, and whether the open vault approved it (openspec:
/// add-pgp-mail-provider, decision 4). The service reads the caller from
/// the binder's uid: its package, and the SHA-256 of the first
/// certificate of its signing lineage, which a key rotation keeps. Plain
/// Dart, so it is tested without a phone.
library;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'mail_apps.dart';

/// Why the service could not pin a caller: no request from it is ever
/// answered, and it cannot be approved.
enum MailCallerRefusal {
  /// Signed by more than one signer, each of which would have to be trusted.
  severalSigners,

  /// A uid that maps to no package, or to several.
  noPackage,

  /// Kemlock itself.
  itself,
}

/// The app asking, as the service read it.
@immutable
class MailCaller {
  const MailCaller({required this.package, required this.cert, this.label, this.refusal});

  /// What the channel carries: `package`, `cert`, `label`, `refused`.
  factory MailCaller.fromMap(Map<Object?, Object?> map) {
    final refused = map['refused'];
    return MailCaller(
      package: map['package'] is String ? map['package']! as String : '',
      cert: map['cert'] is String ? map['cert']! as String : '',
      label: map['label'] is String ? map['label']! as String : null,
      refusal: refused is String
          ? MailCallerRefusal.values.firstWhereOrNull((r) => r.name == refused) ?? MailCallerRefusal.noPackage
          : null,
    );
  }

  final String package;

  /// The SHA-256 of the original certificate of its signing lineage, in
  /// hexadecimal; empty when it was refused.
  final String cert;

  /// Its label, as the phone names it: `Thunderbird`.
  final String? label;
  final MailCallerRefusal? refusal;

  /// What to call it: its label, or else its package.
  String get name => (label?.trim().isNotEmpty ?? false) ? label!.trim() : package;

  @override
  bool operator ==(Object other) =>
      other is MailCaller && other.package == package && other.cert == cert && other.label == label && other.refusal == refusal;

  @override
  int get hashCode => Object.hash(package, cert, label, refusal);

  @override
  String toString() => 'MailCaller($package, $cert${refusal == null ? '' : ', refused: ${refusal!.name}'})';
}

/// Where a caller stands with the open vault.
enum MailCallerStanding {
  /// Its package and certificate match an approval.
  approved,

  /// The vault approved no app of its package.
  unknown,

  /// An app of its package was approved, signed by another certificate:
  /// asked about again, with a warning.
  otherCertificate,

  /// It can never be approved ([MailCallerRefusal]).
  refused,
}

/// Where [caller] stands with [apps], the open vault's approvals. Digests
/// are compared without regard to case.
MailCallerStanding judgeCaller(MailCaller caller, List<MailApp> apps) {
  if (caller.refusal != null || caller.package.isEmpty || caller.cert.isEmpty) return MailCallerStanding.refused;
  final app = apps.firstWhereOrNull((app) => app.package == caller.package);
  if (app == null) return MailCallerStanding.unknown;
  return app.cert.toLowerCase() == caller.cert.toLowerCase() ? MailCallerStanding.approved : MailCallerStanding.otherCertificate;
}

/// The approval [caller] holds in [apps], when it stands approved.
MailApp? approvalOf(MailCaller caller, List<MailApp> apps) =>
    judgeCaller(caller, apps) == MailCallerStanding.approved ? apps.firstWhere((app) => app.package == caller.package) : null;
