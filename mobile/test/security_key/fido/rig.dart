import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kemlock/platform/security_keys.dart';
import 'package:kemlock/security_key/connection.dart';
import 'package:kemlock/security_key/fido/client_pin.dart';
import 'package:kemlock/security_key/fido/get_info.dart';

import '../../fakes/fake_fido_key.dart';
import '../../fakes/fake_security_keys.dart';

/// The two links FIDO2 commands are tested over.
const fidoKinds = [SecurityKeyLinkKind.nfc, SecurityKeyLinkKind.usbHid];

/// A PIN as the bytes the commands take.
Uint8List pinBytes(String pin) => Uint8List.fromList(utf8.encode(pin));

/// A fake key connected over one link, with its FIDO application open.
class Rig {
  Rig._(this.phone, this.fido, this.key, this.kind);

  final FakeSecurityKeys phone;
  final FakeFidoKey fido;
  final FakeKey key;
  final SecurityKeyLinkKind kind;
  late FakeDevice device;
  late SecurityKeyConnection connection;
  late CtapSession session;
  late AuthenticatorInfo info;

  /// Connects [fido] over [kind] and reads what it says of itself.
  static Future<Rig> connect(FakeFidoKey fido, {SecurityKeyLinkKind kind = SecurityKeyLinkKind.nfc}) async {
    final rig = Rig._(FakeSecurityKeys(), fido, FakeKey(productName: 'Example Key', ctap: fido), kind);
    await rig.present();
    return rig;
  }

  /// The key is presented: held to the phone, or plugged in.
  Future<void> present() async {
    device = key.device(kinds: {kind});
    phone.arrive(device);
    final links = device.needsPermission ? await phone.requestPermission(device.id) : null;
    connection = SecurityKeyConnection(
      phone,
      SecurityKeyDevice(
        id: device.id,
        productName: device.productName,
        links:
            links ??
            [
              for (final MapEntry(key: linkKind, value: link) in device.links.entries)
                SecurityKeyLink(id: device.linkId(linkKind), kind: linkKind, extendedLength: link.extendedLength),
            ],
      ),
      now: phone.now,
    );
    session = await connection.openFido();
    info = await getInfo(session);
  }

  /// The key is taken away and presented again, which powers it anew.
  Future<void> reconnect() async {
    phone.remove(device);
    await present();
  }

  ClientPin get clientPin => ClientPin(session, info);

  /// A token for [pin] with [permissions].
  Future<PinToken> token(String pin, int permissions) => clientPin.token(pinBytes(pin), permissions: permissions);

  /// The requests the key got since [mark], as the fake names them.
  List<String> requestsSince(int mark) => fido.requests.sublist(mark);
}

/// Runs [body] as one test per link kind.
void testOverEachLink(String description, Future<void> Function(SecurityKeyLinkKind kind) body) {
  for (final kind in fidoKinds) {
    test('$description, over ${kind.name}', () => body(kind));
  }
}
