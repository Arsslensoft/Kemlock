import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/core/providers.dart';
import 'package:kemlock/core/storage/key_value_store.dart';
import 'package:kemlock/features/export/android_export.dart';
import 'package:kemlock/features/export/credential_export.dart';
import 'package:kemlock/features/export/credential_export_sheet.dart';
import 'package:kemlock/features/import/credential_exchange.dart';
import 'package:kemlock/models/login.dart';
import 'package:kemlock/platform/credential_exchange.dart';
import 'package:kemlock/vault/vault_providers.dart';
import 'package:kemlock/vault/vault_registry.dart';

import '../../fakes/fake_credential_exchange.dart';
import '../../fakes/fake_owner_check.dart';
import '../../helpers/test_app.dart';
import 'transfer_harness.dart';

// The add-credential-exchange plan, task 8.4: Dart's half, over a fake port

const _request = ExportRequest(
  id: 'req-1',
  vaultId: 'main',
  app: '1Password',
  package: 'com.onepassword.android',
  types: {'basic-auth', 'totp'},
);
// The vault RecordingVault opens has the id 'test'; a request for another is a wrong vault, which
// the sheet answers with an error and no button
const _forOpenVault = ExportRequest(
  id: 'req-1',
  vaultId: 'test',
  app: '1Password',
  package: 'com.onepassword.android',
  types: {'basic-auth', 'totp'},
);
const _newer = ExportRequest(id: 'req-2', vaultId: 'main', app: 'Bitwarden', package: 'com.x8bit.bitwarden', types: {'basic-auth'});
const _login = Login(id: 'l1', name: 'Larkspur', username: 'ada', password: 'hunter2-secret', addedAt: 0);

ProviderContainer _container(FakeCredentialExport export, {bool enabled = true, KeyValueStore? store}) {
  final container = ProviderContainer(
    overrides: [
      export.asOverride,
      credentialExportEnabledProvider.overrideWithValue(enabled),
      if (store != null) keyValueStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the target', () {
    test('answers the app that asked with the JSON, and names it with what it asked for', () async {
      final export = FakeCredentialExport();
      final target = AndroidExportTarget(export, _request);

      await target.send(() async => '{"version":1}');

      expect(export.answers.single, (id: 'req-1', json: '{"version":1}'));
      expect(target.appName, '1Password');
      expect(target.appPackage, 'com.onepassword.android');
      expect(target.askedTypes, {'basic-auth', 'totp'});
      expect(target.vaultId, 'main');
    });

    test('says a request that is gone as a failure, with nothing of the data', () async {
      final export = FakeCredentialExport(answerProblem: CredentialExportProblem.gone);

      await expectLater(
        AndroidExportTarget(export, _request).send(() async => '{"password":"hunter2-secret"}'),
        throwsA(isA<CredentialExportFailed>().having((e) => '$e', 'text', isNot(contains('hunter2')))),
      );
    });

    test('tells the app nothing is coming when cancelled', () async {
      final export = FakeCredentialExport();

      await AndroidExportTarget(export, _request).cancel();

      expect(export.refused, ['req-1']);
      expect(export.answers, isEmpty);
    });
  });

  group('the waiting request', () {
    test('is not listened for while export is switched off', () async {
      final export = FakeCredentialExport(waiting: _request);
      final container = _container(export, enabled: false);

      container.listen(pendingExportRequestProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      export.send(_newer);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(pendingExportRequestProvider), isNull);
      expect(export.asked, 0);
    });

    test('is picked up when it arrived before Dart was up, and when it arrives after', () async {
      final export = FakeCredentialExport(waiting: _request);
      final container = _container(export);
      container.listen(pendingExportRequestProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);

      expect(container.read(pendingExportRequestProvider)?.id, 'req-1');

      container.read(pendingExportRequestProvider.notifier).take();
      export.send(_newer);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(pendingExportRequestProvider)?.id, 'req-2');
    });

    test('a newer request tells the older app nothing is coming', () async {
      final export = FakeCredentialExport(waiting: _request);
      final container = _container(export);
      container.listen(pendingExportRequestProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);

      export.send(_newer);
      await Future<void>.delayed(Duration.zero);

      expect(export.refused, ['req-1']);
      expect(container.read(pendingExportRequestProvider)?.id, 'req-2');
    });

    test('taking it hands it to the sheet and refuses nothing; cancelling refuses it', () async {
      final export = FakeCredentialExport(waiting: _request);
      final container = _container(export);
      container.listen(pendingExportRequestProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);

      final taken = container.read(pendingExportRequestProvider.notifier).take();

      expect(taken?.id, 'req-1');
      expect(container.read(pendingExportRequestProvider), isNull);
      expect(export.refused, isEmpty);

      export.send(_newer);
      await Future<void>.delayed(Duration.zero);
      container.read(pendingExportRequestProvider.notifier).cancel();

      expect(export.refused, ['req-2']);
      expect(container.read(pendingExportRequestProvider), isNull);
    });
  });

  group('the five minutes of a request', () {
    // Runs [body] with the clock under the test's hand, over a container that holds [_request] as waiting
    void inTime(void Function(FakeAsync async, ProviderContainer container, FakeCredentialExport export) body) {
      fakeAsync((async) {
        final export = FakeCredentialExport(waiting: _request);
        final container = _container(export);
        container.listen(pendingExportRequestProvider, (_, _) {});
        async.flushMicrotasks();
        body(async, container, export);
      });
    }

    test('drop a request nobody opened a sheet for when they pass', () {
      inTime((async, container, export) {
        expect(container.read(pendingExportRequestProvider)?.id, 'req-1');

        async.elapse(exportRequestLife + const Duration(seconds: 1));

        expect(container.read(pendingExportRequestProvider), isNull);
        expect(export.refused, ['req-1']);
      });
    });

    test('keep running while the sheet has the request, and refuse it when they pass', () {
      inTime((async, container, export) {
        final taken = container.read(pendingExportRequestProvider.notifier).take();
        expect(taken?.id, 'req-1');

        async.elapse(exportRequestLife - const Duration(seconds: 1));
        expect(export.refused, isEmpty);
        async.elapse(const Duration(seconds: 2));

        expect(export.refused, ['req-1']);
        expect(container.read(pendingExportRequestProvider), isNull);
      });
    });

    test('stop when the sheet sends', () {
      inTime((async, container, export) {
        final requests = container.read(pendingExportRequestProvider.notifier);
        final target = AndroidExportTarget(export, requests.take()!, onSettled: requests.settled);

        unawaited(target.send(() async => '{"version":1}'));
        async.flushMicrotasks();
        async.elapse(exportRequestLife * 2);

        expect(export.answers.single.id, 'req-1');
        expect(export.refused, isEmpty);
      });
    });

    test('stop when the sheet fails to send, which ends the request as well', () {
      inTime((async, container, export) {
        export.answerProblem = CredentialExportProblem.gone;
        final requests = container.read(pendingExportRequestProvider.notifier);
        final target = AndroidExportTarget(export, requests.take()!, onSettled: requests.settled);

        unawaited(target.send(() async => '{}').catchError((Object _) {}));
        async.flushMicrotasks();
        async.elapse(exportRequestLife * 2);

        expect(export.refused, isEmpty);
      });
    });

    test('stop when the sheet is cancelled, which refuses the request once', () {
      inTime((async, container, export) {
        final requests = container.read(pendingExportRequestProvider.notifier);
        final target = AndroidExportTarget(export, requests.take()!, onSettled: requests.settled);

        unawaited(target.cancel());
        async.flushMicrotasks();
        async.elapse(exportRequestLife * 2);

        expect(export.refused, ['req-1']);
      });
    });

    test('a newer request starts its own five minutes, which the older one settling does not stop', () {
      inTime((async, container, export) {
        final requests = container.read(pendingExportRequestProvider.notifier);
        final target = AndroidExportTarget(export, requests.take()!, onSettled: requests.settled);
        async.elapse(const Duration(minutes: 4));

        // The newer request starts its own five minutes; the older one's settling does not stop them
        export.send(_newer);
        async.flushMicrotasks();
        unawaited(target.cancel());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 4));
        expect(container.read(pendingExportRequestProvider)?.id, 'req-2');

        async.elapse(const Duration(minutes: 2));
        expect(container.read(pendingExportRequestProvider), isNull);
        expect(export.refused, ['req-1', 'req-2']);
      });
    });
  });

  group('the registration', () {
    test('lists the vaults the lock screen offers, with the types Kemlock writes and no more', () async {
      final export = FakeCredentialExport();
      final store = KeyValueStore.memory();
      final container = _container(export, store: store);
      container.read(vaultRegistryProvider);

      await container.read(credentialExportRegistrationProvider.future);

      final registration = export.registrations.single;
      expect(registration.types, credentialTypesKept);
      for (final vault in registration.vaults) {
        expect(vault.vaultId, isNotEmpty);
      }
      // Nothing a vault holds is in what is listed
      expect(registration.vaults.map((v) => v.vaultId).toSet().length, registration.vaults.length);
    });

    test('lists nothing while export is switched off', () async {
      final export = FakeCredentialExport();
      final container = _container(export, enabled: false);

      await container.read(credentialExportRegistrationProvider.future);

      expect(export.registrations, isEmpty);
    });

    test('asks once to take Kemlock out of the lists while export is switched off', () async {
      final export = FakeCredentialExport();
      final container = _container(export, enabled: false);

      await container.read(credentialExportRegistrationProvider.future);

      expect(export.cleared, 1);
      expect(export.registrations, isEmpty);
    });

    test('never clears the lists while export is switched on', () async {
      final export = FakeCredentialExport();
      final container = _container(export, store: KeyValueStore.memory());
      container.read(vaultRegistryProvider);

      await container.read(credentialExportRegistrationProvider.future);

      expect(export.cleared, 0);
      expect(export.registrations, hasLength(1));
    });

    test('does not show, or stop on, a clear that fails', () async {
      final export = FakeCredentialExport(clearProblem: CredentialExportProblem.registerFailed);
      final container = _container(export, enabled: false);

      await container.read(credentialExportRegistrationProvider.future);

      expect(export.cleared, 1);
    });

    test('names the first vault by nothing and another by its name', () async {
      final export = FakeCredentialExport();
      final store = KeyValueStore.memory({
        keyConfig: jsonEncode({'name': ''}),
        '$keyConfig::work': jsonEncode({'name': 'Work'}),
      });
      final container = _container(export, store: store);
      container.read(vaultRegistryProvider).setListed('work', true);

      await container.read(credentialExportRegistrationProvider.future);

      final names = {for (final vault in export.registrations.single.vaults) vault.vaultId: vault.name};
      expect(names, {mainVault: null, 'work': 'Work'});
    });
  });

  group('the sheet for a request', () {
    testWidgets('names the app, answers it after the owner check, and carries the vault the app asked for', (tester) async {
      final export = FakeCredentialExport();
      final ownerCheck = FakeOwnerCheck();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: AndroidExportTarget(export, _forOpenVault)),
        vault: RecordingVault(logins: const [_login]),
        ownerCheck: ownerCheck,
      );
      await tester.pump(const Duration(seconds: 10));

      expect(find.text(t('export.cxf.body.named', {'app': '1Password'})), findsOneWidget);
      // The label is the other app's to choose; the package name under it is the system's
      expect(find.text(t('export.cxf.package', {'package': 'com.onepassword.android'})), findsOneWidget);
      await tapOn(tester, find.text(t('export.cxf.button')));

      expect(ownerCheck.reasons, hasLength(1));
      expect(export.answers.single.id, 'req-1');
      expect(export.answers.single.json, contains('Larkspur'));
      expect(export.refused, isEmpty);
    });

    testWidgets('a cancelled owner check refuses the request and answers nothing', (tester) async {
      final export = FakeCredentialExport();
      await openSheet(
        tester,
        (context) => showCredentialExportSheet(context, target: AndroidExportTarget(export, _forOpenVault)),
        vault: RecordingVault(logins: const [_login]),
        ownerCheck: FakeOwnerCheck(passes: false),
      );
      await tester.pump(const Duration(seconds: 10));

      await tapOn(tester, find.text(t('export.cxf.button')));

      expect(export.answers, isEmpty);
      expect(export.refused, contains('req-1'));
    });
  });
}
