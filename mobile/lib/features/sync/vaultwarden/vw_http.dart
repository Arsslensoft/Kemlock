/// The HTTP client Vaultwarden sync talks through: the system's trust for
/// certificates, plus, for a server with a self-signed certificate, the one
/// certificate the user compared and pinned at setup.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The SHA-256 of a certificate's DER bytes, as pairs of upper-case hex
/// digits joined by colons, the way browsers and `openssl` show it.
String certificateFingerprint(List<int> der) =>
    sha256.convert(der).bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

/// A fingerprint however it was written or pasted: hex digits only, upper case.
String normalizeFingerprint(String fingerprint) => fingerprint.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase();

/// A client that trusts what the system trusts and, when [pin] is set, a
/// certificate the system doesn't trust but whose fingerprint is [pin].
/// Nothing else is accepted: never "any certificate".
http.Client vwHttpClient({String? pin}) {
  final io = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  if (pin != null) {
    final wanted = normalizeFingerprint(pin);
    io.badCertificateCallback = (certificate, host, port) => normalizeFingerprint(certificateFingerprint(certificate.der)) == wanted;
  }
  return IOClient(io);
}

/// The fingerprint of the certificate [server] shows, when the system
/// doesn't trust it; null when it does, or when nothing answers. Nothing is
/// sent but the TLS handshake.
Future<String?> untrustedCertificate(Uri server, {Duration timeout = const Duration(seconds: 15)}) async {
  X509Certificate? seen;
  try {
    final socket = await SecureSocket.connect(
      server.host,
      server.hasPort ? server.port : 443,
      timeout: timeout,
      onBadCertificate: (certificate) {
        seen = certificate;
        return false;
      },
    );
    socket.destroy();
  } catch (_) {
    // A refused certificate ends the handshake; anything else means no answer
  }
  final certificate = seen;
  return certificate == null ? null : certificateFingerprint(certificate.der);
}
