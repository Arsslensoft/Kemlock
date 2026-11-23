// The problems a Kemlock Server run shows (add-kemlock-server-sync, task 8.6):
// problemOf reads a client error and a stopped run, and each problem has words
// in English and French (the existing sync_messages_test words every one).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/spaces/server_spaces.dart' show SpaceSyncError, SpaceSyncIssue;
import 'package:kemlock/features/sync/kemlock/km_api.dart';
import 'package:kemlock/features/sync/kemlock/km_sync.dart';
import 'package:kemlock/features/sync/sync.dart';

Map<String, Object?> _messages(String locale) => jsonDecode(File('assets/i18n/$locale.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  group('problemOf', () {
    test('reads a failed request', () {
      expect(problemOf(const KmError(KmProblem.network)), SyncProblem.network);
      expect(problemOf(const KmError(KmProblem.insecure)), SyncProblem.insecure);
      expect(problemOf(const KmError(KmProblem.address)), SyncProblem.kemlockAddress);
      expect(problemOf(const KmError(KmProblem.stale)), SyncProblem.conflict);
      expect(problemOf(const KmError(KmProblem.server, status: 500)), SyncProblem.server);
      expect(problemOf(const KmError(KmProblem.rateLimited, retryAfter: 30)), SyncProblem.server);
      expect(problemOf(const KmError(KmProblem.tooLarge)), SyncProblem.server);
    });

    test('says a session the server ended is ended, and one ended by a reused refresh token is ended for safety', () {
      expect(problemOf(const KmError(KmProblem.sessionEnded, reason: 'signed-out')), SyncProblem.sessionEnded);
      expect(problemOf(const KmError(KmProblem.sessionEnded)), SyncProblem.sessionEnded);
      expect(problemOf(const KmError(KmProblem.auth, status: 401)), SyncProblem.sessionEnded);
      expect(problemOf(const KmError(KmProblem.sessionEnded, reason: 'refresh-reuse')), SyncProblem.sessionReused);
    });

    test('reads a run that stopped before changing anything', () {
      expect(problemOf(const KmSyncError(KmSyncIssue.older)), SyncProblem.kemlockOlder);
      expect(problemOf(const KmSyncError(KmSyncIssue.removals, count: 7)), SyncProblem.removals);
    });

    test('reads a space’s run that stopped before changing anything, with its own words for a chain and for keys being replaced', () {
      expect(problemOf(const SpaceSyncError(SpaceSyncIssue.cantBeChecked)), SyncProblem.spaceCantBeChecked);
      expect(problemOf(const SpaceSyncError(SpaceSyncIssue.keysPending)), SyncProblem.spaceKeysPending);
      expect(problemOf(const SpaceSyncError(SpaceSyncIssue.older)), SyncProblem.kemlockOlder);
      expect(problemOf(const SpaceSyncError(SpaceSyncIssue.removals, count: 7)), SyncProblem.removals);
    });

    test('leaves what it does not know as a server problem, and the other backends’ errors as they were', () {
      expect(problemOf(StateError('x')), SyncProblem.server);
    });
  });

  test('every problem has a message in English and French, none the same as the Vaultwarden one it replaces', () {
    final en = _messages('en');
    final fr = _messages('fr');
    for (final problem in SyncProblem.values) {
      expect(en['sync.problem.${problem.name}'], isA<String>(), reason: problem.name);
      expect(fr['sync.problem.${problem.name}'], isA<String>(), reason: problem.name);
    }
    expect(en['sync.problem.sessionEnded'], isNot(en['sync.problem.signedOut']));
    expect(en['sync.problem.kemlockOlder'], isNot(en['sync.problem.older']));
    expect(en['sync.problem.sessionEnded'], contains('entries are kept'));
    expect(fr['sync.problem.sessionEnded'], contains('conservées'));
  });
}
