import 'dart:async';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/setup_links.dart';

/// Stands in for the links other apps hand Kemlock: the one it was opened
/// with, and those [send] delivers while it runs.
class FakeSetupLinks implements SetupLinks {
  FakeSetupLinks({this.opening});

  /// The link the app was opened with, handed over once.
  String? opening;

  final _incoming = StreamController<String>.broadcast();

  Override get asOverride => setupLinksProvider.overrideWithValue(this);

  /// Another app hands [link] over while the app runs.
  void send(String link) => _incoming.add(link);

  @override
  Future<String?> initial() async {
    final link = opening;
    opening = null;
    return link;
  }

  @override
  Stream<String> get incoming => _incoming.stream;
}
