/// Offline mode and the one gate every network request of the app's own
/// code passes (openspec: add-offline-mode). While the switch is on, the
/// gate refuses each request before it is made.
///
/// Read [offlineProvider] to show that a feature is paused; make a client
/// with [gatedClientProvider] or [gatedClientFactory], or call
/// [NetworkGate.check] before opening a connection any other way; read an
/// answer with [readAnswer], which stops at a limit:
///
/// ```dart
/// final client = ref.watch(gatedClientProvider);
/// ref.read(networkGateProvider).check(server);
/// ref.read(offlineProvider.notifier).set(true);
/// ```
///
/// `test/platform/network_callers_test.dart` fails when a file other than
/// this one and the three it names makes a client, a socket, a browser
/// launch or a store call.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/providers.dart';
import '../core/storage/key_value_store.dart';
import '../vault/vault_registry.dart';

/// Whether [store] says offline mode is on: [keyOffline] holds `{"on": true}`.
/// Absent, or anything else, is off.
bool readOffline(KeyValueStore store) {
  final raw = store.getItem(keyOffline);
  if (raw == null) return false;
  try {
    final json = jsonDecode(raw);
    return json is Map<String, Object?> && json['on'] == true;
  } on FormatException {
    return false;
  }
}

/// Offline mode: one switch for the phone, off until turned on, kept
/// across restarts and through a reset.
class Offline extends Notifier<bool> {
  @override
  bool build() {
    watchKeys(ref, [keyOffline]);
    return readOffline(ref.watch(keyValueStoreProvider));
  }

  /// Turns offline mode on or off. Off removes the key.
  void set(bool on) {
    final store = ref.read(keyValueStoreProvider);
    if (on) {
      store.setItem(keyOffline, jsonEncode({'on': true}));
    } else {
      store.removeItem(keyOffline);
    }
  }
}

/// Whether offline mode is on.
final offlineProvider = NotifierProvider<Offline, bool>(Offline.new);

/// What the gate throws in place of making a request while offline mode is
/// on. It is an [http.ClientException], so code that already handles a
/// failed request handles it.
class OfflineException extends http.ClientException {
  OfflineException([Uri? uri]) : super('Offline mode is on.', uri);
}

/// Decides whether a request may be made.
class NetworkGate {
  const NetworkGate(this._offline);

  final bool Function() _offline;

  /// Whether offline mode is on now.
  bool get offline => _offline();

  /// Throws an [OfflineException] while offline mode is on. Call it before
  /// anything that opens a connection; [uri] is where it would have gone.
  void check([Uri? uri]) {
    if (offline) throw OfflineException(uri);
  }
}

/// The gate. It reads the stored switch each time, so it is right from the
/// moment the switch is written.
final networkGateProvider = Provider<NetworkGate>((ref) {
  final store = ref.watch(keyValueStoreProvider);
  return NetworkGate(() => readOffline(store));
});

/// A client whose every request passes the gate first. The client it wraps
/// is made on the first request the gate lets through, so making a
/// [GatedClient] opens nothing.
class GatedClient extends http.BaseClient {
  GatedClient(this._make, this._gate);

  final http.Client Function() _make;
  final NetworkGate _gate;
  http.Client? _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _gate.check(request.url);
    return (_inner ??= _make()).send(request);
  }

  @override
  void close() {
    _inner?.close();
    _inner = null;
  }
}

/// Makes the plain client [gatedClientProvider] wraps. Tests override it
/// with a `MockClient` to see what the gate lets through.
final plainClientProvider = Provider<http.Client Function()>(
  (ref) =>
      () => http.Client(),
);

/// A gated client over a plain one, for requests that need no pinned
/// certificate.
final gatedClientProvider = Provider<http.Client>((ref) {
  final client = GatedClient(ref.watch(plainClientProvider), ref.watch(networkGateProvider));
  ref.onDispose(client.close);
  return client;
});

/// A factory of gated clients over [make], for Vaultwarden, which makes a
/// client per pinned certificate.
http.Client Function(String? pin) gatedClientFactory(NetworkGate gate, http.Client Function(String? pin) make) =>
    (pin) => GatedClient(() => make(pin), gate);

/// What [readAnswer] throws for an answer longer than it takes. It is an
/// [http.ClientException], so code that already handles a failed request
/// handles it.
class AnswerTooLarge extends http.ClientException {
  AnswerTooLarge([Uri? uri]) : super('The answer is larger than it may be.', uri);
}

/// [response] read whole, as `http.Response.fromStream` reads it, but never
/// past [maxBytes]: a server's answer is read into memory, and one that
/// never ends would fill it. An answer whose `Content-Length` is over the
/// limit is refused before any of it is read, and one that runs past it is
/// dropped there and its connection closed; both throw [AnswerTooLarge].
Future<http.Response> readAnswer(http.StreamedResponse response, int maxBytes) async {
  final url = response.request?.url;
  if ((response.contentLength ?? 0) > maxBytes) {
    // Listening and leaving at once closes the connection
    unawaited(response.stream.listen(null, onError: (Object _) {}).cancel());
    throw AnswerTooLarge(url);
  }
  final body = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    if (body.length + chunk.length > maxBytes) throw AnswerTooLarge(url);
    body.add(chunk);
  }
  return http.Response.bytes(
    body.takeBytes(),
    response.statusCode,
    request: response.request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}

/// What a live socket is to the code that listens on it: the frames it receives, and the end of it. The socket
/// of [connectLiveSocket] is one; tests make their own.
abstract interface class LiveSocket {
  /// The text frames the server sends, ending when the socket closes. An error ends it too.
  Stream<String> get frames;

  /// Closes the socket. Closing a closed socket does nothing.
  Future<void> close();
}

/// Opens a [LiveSocket] to [url], carrying [headers] on the upgrade request: the Kemlock Server's `/kem/v1/live`,
/// whose upgrade carries DPoP (add-kemlock-server-sync, design 13). Whoever calls this passes the gate first, as
/// [connectLiveSocket] does.
typedef LiveSocketConnector = Future<LiveSocket> Function(Uri url, {Map<String, String> headers, String? pin});

/// The ping that finds a dead connection: a socket whose far end vanished would otherwise stay open for ever.
const liveSocketPing = Duration(seconds: 30);

/// The longest text frame taken; a nudge carries its type and nothing else.
const maxLiveFrameBytes = 4096;

class _IoLiveSocket implements LiveSocket {
  _IoLiveSocket(this._socket) : frames = _socket.where((frame) => frame is String && frame.length <= maxLiveFrameBytes).cast<String>();

  final WebSocket _socket;

  @override
  final Stream<String> frames;

  @override
  Future<void> close() async {
    try {
      await _socket.close(WebSocketStatus.normalClosure);
    } on Object {
      // Already closed, or the far end is gone
    }
  }
}

/// Opens a WebSocket through the gate, with dart:io's own: the only place the app makes one. The gate refuses it
/// while offline mode is on, an address that isn't `wss` is refused (`ws` only when [allowPlain], which tests use
/// on loopback), and a certificate the system doesn't trust is accepted only when its SHA-256 is [pin], as the
/// pinned HTTP client of Vaultwarden and Kemlock Server does. The upgrade follows no redirect.
Future<LiveSocket> connectLiveSocket(
  NetworkGate gate,
  Uri url, {
  Map<String, String> headers = const {},
  String? pin,
  bool allowPlain = false,
  Duration timeout = const Duration(seconds: 30),
}) async {
  gate.check(url);
  if (url.scheme != 'wss' && !(allowPlain && url.scheme == 'ws')) {
    throw WebSocketException('The live socket needs wss.');
  }
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..autoUncompress = false;
  if (pin != null) {
    final wanted = pin.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase();
    client.badCertificateCallback = (certificate, host, port) {
      final got = hash.sha256.convert(certificate.der).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
      return got == wanted;
    };
  }
  try {
    final socket = await WebSocket.connect(url.toString(), headers: headers, customClient: client).timeout(timeout);
    socket.pingInterval = liveSocketPing;
    return _IoLiveSocket(socket);
  } on Object {
    client.close(force: true);
    rethrow;
  }
}

/// Opens the live socket of the app, through the gate. Tests override it with a fake server.
final liveSocketConnectorProvider = Provider<LiveSocketConnector>((ref) {
  final gate = ref.watch(networkGateProvider);
  return (url, {headers = const {}, pin}) => connectLiveSocket(gate, url, headers: headers, pin: pin);
});

/// The backstop `main` installs as `HttpOverrides.global`: while offline
/// mode is on, no `dart:io` HTTP client can be made, by the app's code or a
/// package's. The gate is still what the app's own requests go through:
/// this sees neither raw sockets nor native code.
class GatedHttpOverrides extends HttpOverrides {
  GatedHttpOverrides(this._gate);

  final NetworkGate _gate;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    _gate.check();
    return super.createHttpClient(context);
  }
}
