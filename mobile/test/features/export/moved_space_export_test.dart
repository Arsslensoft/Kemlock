import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/export/credential_export.dart';
import 'package:kemlock/features/export/space_export.dart';
import 'package:kemlock/features/spaces/space_scope.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/vault/vault_controller.dart';

// A WebDAV space that moved to Kemlock Server keeps its WebDAV id on the phone, while its chain, and so its policies, are
// reported under the UUID the server knows it by (`serverSpaceUuid`). The export policy looks the space up under both
// (docs/plans/add-server-spaces.md, tasks 7.4 and 8.4).
void main() {
  const movedId = 'fam-01';
  final uuid = serverSpaceUuid(movedId);

  SpaceExportRule rule({Set<String> blocked = const {}, Set<String> known = const {}}) =>
      SpaceExportRule(blocked: blocked, known: known, isServerSpace: (id) => true);

  test('the UUID the server knows a moved space by is not its WebDAV id', () {
    expect(uuid, isNot(movedId));
  });

  group('the file exports', () {
    test('leave out a moved space whose chain forbids export, which is reported under its UUID', () {
      final forbidding = rule(blocked: {uuid}, known: {uuid});

      expect(forbidding.forbids(movedId), isTrue);
      expect(forbidding.unknown(movedId), isFalse, reason: 'it is blocked, not unknown');
    });

    test('take a moved space whose chain allows export and was read under its UUID', () {
      final allowing = rule(known: {uuid});

      expect(allowing.forbids(movedId), isFalse);
      expect(allowing.unknown(movedId), isFalse, reason: 'its policy is known');
    });

    test('keep out a moved space whose chain was never read', () {
      final unread = rule();

      expect(unread.forbids(movedId), isFalse);
      expect(unread.unknown(movedId), isTrue);
    });

    test('still look a space up under the id it has, as a server space made on the server', () {
      final made = rule(blocked: {uuid}, known: {uuid});

      expect(made.forbids(uuid), isTrue);
      expect(made.forbids('another-space'), isFalse);
      expect(made.forbids(''), isFalse);
      expect(made.forbids(null), isFalse);
    });
  });

  group('the Credential Exchange export', () {
    const moved = Login(id: 'l2', name: 'Family router', username: 'admin', password: 'secret', spaceId: movedId, addedAt: 0);

    test('names a moved space whose chain forbids export, though its items carry the WebDAV id', () {
      final plan = planCredentialExport(
        const VaultState(
          phase: VaultPhase.unlocked,
          logins: [moved],
          vault: VaultInfo(id: 'test'),
        ),
        inServerSpace: (id) => true,
        blockedSpaces: {uuid},
        spaceName: (id) => id == movedId ? 'Family' : null,
      );

      expect(plan.blocked, {'Family': 1});
      expect(plan.serverSpaceItems, 0, reason: 'counted as blocked, not as a server space’s item');
      expect(plan.all.logins, isEmpty);
    });
  });
}
