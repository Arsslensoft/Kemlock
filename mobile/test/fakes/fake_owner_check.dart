import 'dart:async';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/features/vault/owner_check.dart';

/// Stands in for the check that whoever holds the open vault is its owner
/// (`features/vault/owner_check.dart`), for the sheets that ask it: it
/// answers at once with [passes], and keeps each reason it was asked with.
class FakeOwnerCheck {
  FakeOwnerCheck({this.passes = true, this.whileAsking});

  /// Whether the person passes the next checks; false as if they cancelled.
  bool passes;

  /// Runs while a check is up, before it answers: what the app does while the person takes their time.
  FutureOr<void> Function()? whileAsking;

  /// The reason of every check asked, in order.
  final List<String> reasons = [];

  Override get asOverride => ownerCheckProvider.overrideWithValue((context, ref, reason) async {
    reasons.add(reason);
    await whileAsking?.call();
    return passes;
  });
}
