import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/features/sync/kemlock/km_host.dart';
import 'package:kemlock/features/sync/kemlock/km_models.dart';
import 'package:kemlock/features/sync/kemlock_host_factory.dart';
import 'package:kemlock/features/sync/kemlock_server_spaces.dart';

import '../../fakes/fake_attachments.dart';
import '../sync/kemlock/km_phone_kit.dart';

// A server space carries the files of its notes and File items only when the host the spaces run through keeps files
const _target = KemlockTarget(
  accountId: '00000000-0000-4000-8000-000000000001',
  email: 'me@example.com',
  servers: [KemlockServer(url: 'https://kem.example.com')],
  deviceId: 'device-1',
);

KmHost _host({VaultKmFiles? files}) => KmHost(
  values: KmMemoryValues(),
  clientFor: (_) => throw UnimplementedError(),
  proofsFor: (_) async => null,
  fileStore: files,
);

void main() {
  test('the spaces of a host that keeps files are given its file store', () {
    final files = VaultKmFiles(FakeAttachmentStore(), 'vault-1');

    expect(kmServerSpacesOf(_host(files: files), _target).files, same(files));
  });

  test('the spaces of a host that keeps none carry none', () {
    expect(kmServerSpacesOf(_host(), _target).files, isNull);
  });
}
